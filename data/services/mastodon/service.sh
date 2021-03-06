
######
# service specific configuration
# you should setup your service here
######

# overrides service specific docker-variables
declare -a containers=( "${SERVICE_NAME}-postgres-dockerbunker" "${SERVICE_NAME}-redis-dockerbunker" "${SERVICE_NAME}-service-dockerbunker" "${SERVICE_NAME}-streaming-dockerbunker" "${SERVICE_NAME}-sidekiq-dockerbunker" "${SERVICE_NAME}-elasticsearch-dockerbunker" )
declare -a add_to_network=( "${SERVICE_NAME}-service-dockerbunker" "${SERVICE_NAME}-streaming-dockerbunker" )
declare -A volumes=( [${SERVICE_NAME}-data-vol-1]="/mastodon/public/system" [${SERVICE_NAME}-data-vol-2]="/mastodon/public/assets" [${SERVICE_NAME}-data-vol-3]="/mastodon/public/packs" [${SERVICE_NAME}-postgres-vol-1]="/var/lib/postgresql/data" [${SERVICE_NAME}-elasticsearch-vol-1]="/usr/share/elasticsearch/data" [${SERVICE_NAME}-redis-vol-1]="/data" )
declare -a networks=( "dockerbunker-${SERVICE_NAME}" )
declare -A IMAGES=( [service]="tootsuite/mastodon:v2.9.4" [redis]="redis:5.0-alpine" [postgres]="postgres:9.6-alpine" [elasticsearch]="docker.elastic.co/elasticsearch/elasticsearch-oss:6.1.3" )

if [[ $1 == "make_admin" ]];then
	if [[ -z $2 || $3 ]];then
		echo "Usage: "${BASE_DIR}"/data/services/${SERVICE_NAME}/service.sh make_admin username"
		exit 1
	else
		mastodon_makeadmin_dockerbunker $2
		exit 0
	fi
fi

# service specific functions
# to setup save service specific docker-variables to environment file
upgrade() {

	get_current_images_sha256

	docker_pull

	stop_containers
	remove_containers

	mastodon_postgres_dockerbunker
	mastodon_redis_dockerbunker
	mastodon_dbmigrateandprecompileassets_dockerbunker

	[[ ${ES_ENABLED} ]] && docker_run mastodon_elasticsearch_dockerbunker

	docker_run mastodon_service_dockerbunker
	docker_run mastodon_sidekiq_dockerbunker
	docker_run mastodon_streaming_dockerbunker

	delete_old_images

	start_containers

	echo -en "\n  \e[3m\xe2\x86\x92 Execute \`tootctl cache clear\`\e[0m "
	docker exec -t mastodon-service-dockerbunker sh -c 'tootctl cache clear'

	sleep 5

	restart_nginx
}

configure() {
	pre_configure_routine

	echo -e "# \e[4mMastodon Settings\e[0m"

	set_domain

	configure_mx

	# avoid tr illegal byte sequence in macOS when generating random strings
	if [[ $OSTYPE =~ "darwin" ]];then
		if [[ $LC_ALL ]];then
			oldLC_ALL=$LC_ALL
			export LC_ALL=C
		else
			export LC_ALL=C
		fi
	fi
	cat <<-EOF >> "${SERVICE_ENV}"
	PROPER_NAME="${PROPER_NAME}"
	SERVICE_NAME="${SERVICE_NAME}"
	SSL_CHOICE=${SSL_CHOICE}
	LE_EMAIL=${LE_EMAIL}

	SERVICE_DOMAIN="${SERVICE_DOMAIN}"
	LOCAL_DOMAIN=${SERVICE_DOMAIN}
	SECRET_KEY_BASE=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 128)
	OTP_SECRET=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 128)
	VAPID_PRIVATE_KEY=
	VAPID_PUBLIC_KEY=

	REDIS_HOST=redis
	REDIS_PORT=6379
	DB_HOST=postgres
	DB_USER=postgres
	DB_NAME=postgres
	DB_PASS=
	DB_PORT=5432
	ES_HOST=es
	ES_PORT=9200

	SMTP_SERVER=${MX_HOSTNAME}
	SMTP_PORT=587
	SMTP_LOGIN=${MX_EMAIL}
	SMTP_PASSWORD=${MX_PASSWORD}
	SMTP_FROM_ADDRESS=${MX_EMAIL}
	STREAMING_CLUSTER_NUM=1

	SERVICE_SPECIFIC_MX=${SERVICE_SPECIFIC_MX}
	EOF

	source "${SERVICE_ENV}"
	if [[ $OSTYPE =~ "darwin" ]];then
		[[ $oldLC_ALL ]] && export LC_ALL=$oldLC_ALL || unset LC_ALL
	fi

	echo ""

	mastodon_generatevapidkeys_dockerbunker
	source "${ENV_DIR}"/${SERVICE_NAME}_tmp.env
	rm "${ENV_DIR}"/${SERVICE_NAME}_tmp.env

	sed -i "s/VAPID_PRIVATE_KEY=.*/VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}/" "${ENV_DIR}"/${SERVICE_NAME}.env
	sed -i "s/VAPID_PUBLIC_KEY=.*/VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}/" "${ENV_DIR}"/${SERVICE_NAME}.env

	post_configure_routine
}
setup() {

	initial_setup_routine

	SUBSTITUTE=( "\${SERVICE_DOMAIN}" )
	basic_nginx

	echo -en "\n\e[1mStarting postgres container\e[0m"
	mastodon_postgres_dockerbunker
	exit_response

	echo -en "\n\e[1mStarting redis container\e[0m"
	mastodon_redis_dockerbunker
	exit_response

	mastodon_dbmigrateandprecompileassets_dockerbunker

	docker_run mastodon_elasticsearch_dockerbunker
	docker_run mastodon_streaming_dockerbunker
	docker_run mastodon_service_dockerbunker
	docker_run mastodon_sidekiq_dockerbunker

	post_setup_routine

	echo -e "\nAfter signing up on ${SERVICE_DOMAIN} make your user an admin by running\n\n\ ${SERVICES_DIR}/${SERVICE_NAME}/service.sh make_admin username\n"

}
