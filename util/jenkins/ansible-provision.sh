#!/usr/bin/env bash

# Ansible provisioning wrapper script that
# assumes the following parameters set
# as environment variables
#
# - github_username
# - server_type
# - instance_type
# - region
# - aws_account
# - keypair
# - ami
# - root_ebs_size
# - security_group
# - dns_zone
# - dns_name
# - environment
# - name_tag
set -x
env
export PYTHONUNBUFFERED=1
export BOTO_CONFIG=/var/lib/jenkins/${aws_account}.boto

run_ansible() {
  ansible-playbook $@
  ret=$?
  if [[ $ret -ne 0 ]]; then
    exit $ret
  fi
}

# This DATE_TIME will be used as instance launch time tag
TERMINATION_DATE_TIME=`date +"%m-%d-%Y %T" --date="-7 days ago"`

if [[ -z $BUILD_USER ]]; then
    BUILD_USER=jenkins
fi

if [[ -z $BUILD_USER_ID ]]; then
    BUILD_USER_ID=edx-sandbox
fi


if [[ -z $WORKSPACE ]]; then
    dir=$(dirname $0)
    source "$dir/ascii-convert.sh"
else
    source "$WORKSPACE/configuration/util/jenkins/ascii-convert.sh"
fi

if [[ -z $static_url_base ]]; then
  static_url_base="/static"
fi

if [[ -z $github_username  ]]; then
  github_username=$BUILD_USER_ID
fi

if [[ ! -f $BOTO_CONFIG ]]; then
  echo "AWS credentials not found for $aws_account"
  exit 1
fi

extra_vars_file="/var/tmp/extra-vars-$$.yml"
sandbox_vars_file="${WORKSPACE}/configuration-secure/ansible/vars/developer-sandbox.yml"
extra_var_arg="-e@${extra_vars_file}"

if [[ $edx_internal == "true" ]]; then
    # if this is a an edx server include
    # the secret var file
    extra_var_arg="-e@${sandbox_vars_file} -e@${extra_vars_file}"
fi

if [[ -z $region ]]; then
  region="us-east-1"
fi

# edX has reservations for sandboxes in this zone, don't change without updating reservations.
if [[ -z $zone ]]; then
  zone="us-east-1c"
fi

if [[ -z $vpc_subnet_id ]]; then
  vpc_subnet_id="subnet-cd867aba"
fi

if [[ -z $elb ]]; then
  elb="false"
fi

if [[ -z $dns_name ]]; then
  dns_name=${github_username}
fi

if [[ -z $name_tag ]]; then
  name_tag=${github_username}-${environment}
fi

if [[ -z $ami ]]; then
  if [[ $server_type == "full_edx_installation" ]]; then
    ami="ami-41f38d24"
  elif [[ $server_type == "ubuntu_12.04" || $server_type == "full_edx_installation_from_scratch" ]]; then
    ami="ami-c15bebaa"
  elif [[ $server_type == "ubuntu_14.04(experimental)" ]]; then
    ami="ami-2dcf7b46"
  fi
fi

if [[ -z $instance_type ]]; then
  instance_type="t2.medium"
fi

if [[ -z $enable_newrelic ]]; then
  enable_newrelic="false"
fi

if [[ -z $enable_datadog ]]; then
  enable_datadog="false"
fi

if [[ -z $performance_course ]]; then
  performance_course="false"
fi

if [[ -z $demo_test_course ]]; then
  demo_test_course="false"
fi

if [[ -z $edx_demo_course ]]; then
  edx_demo_course="false"
fi

if [[ -z $enable_client_profiling ]]; then
  enable_client_profiling="false"
fi

# Lowercase the dns name to deal with an ansible bug
dns_name="${dns_name,,}"

deploy_host="${dns_name}.${dns_zone}"
ssh-keygen -f "/var/lib/jenkins/.ssh/known_hosts" -R "$deploy_host"

cd playbooks/edx-east

cat << EOF > $extra_vars_file
ansible_ssh_private_key_file: /var/lib/jenkins/${keypair}.pem
edx_platform_version: $edxapp_version
forum_version: $forum_version
notifier_version: $notifier_version
xqueue_version: $xqueue_version
xserver_version: $xserver_version
ora_version: $ora_version
ease_version: $ease_version
certs_version: $certs_version
discern_version: $discern_version
configuration_version: $configuration_version
ECOMMERCE_VERSION: $ecommerce_version
PROGRAMS_VERSION: $programs_version
EDXAPP_STATIC_URL_BASE: $static_url_base
EDXAPP_LMS_NGINX_PORT: 80
EDXAPP_LMS_PREVIEW_NGINX_PORT: 80
EDXAPP_CMS_NGINX_PORT: 80
ECOMMERCE_NGINX_PORT: 80
ECOMMERCE_SSL_NGINX_PORT: 443
NGINX_SET_X_FORWARDED_HEADERS: True
EDX_ANSIBLE_DUMP_VARS: true
migrate_db: "yes"
openid_workaround: True
rabbitmq_ip: "127.0.0.1"
rabbitmq_refresh: True
COMMON_HOSTNAME: $dns_name
COMMON_DEPLOYMENT: edx
COMMON_ENVIRONMENT: sandbox
# User provided extra vars
$extra_vars
EOF

if [[ $basic_auth == "true" ]]; then
    # vars specific to provisioning added to $extra-vars
    cat << EOF_AUTH >> $extra_vars_file
COMMON_ENABLE_BASIC_AUTH: True
COMMON_HTPASSWD_USER: $auth_user
COMMON_HTPASSWD_PASS: $auth_pass
XQUEUE_BASIC_AUTH_USER: $auth_user
XQUEUE_BASIC_AUTH_PASSWORD: $auth_pass
EOF_AUTH

else
    cat << EOF_AUTH >> $extra_vars_file
COMMON_ENABLE_BASIC_AUTH: False
EOF_AUTH

fi

if [[ $enable_client_profiling == "true" ]]; then
    cat << EOF_PROFILING >> $extra_vars_file
EDXAPP_SESSION_SAVE_EVERY_REQUEST: True
EOF_PROFILING
fi

if [[ $edx_internal == "true" ]]; then
    # if this isn't a public server add the github
    # user and set edx_internal to True so that
    # xserver is installed
    cat << EOF >> $extra_vars_file
EDXAPP_PREVIEW_LMS_BASE: preview-${deploy_host}
EDXAPP_LMS_BASE: ${deploy_host}
EDXAPP_CMS_BASE: studio-${deploy_host}
EDXAPP_SITE_NAME: ${deploy_host}
CERTS_DOWNLOAD_URL: "http://${deploy_host}:18090"
CERTS_VERIFY_URL: "http://${deploy_host}:18090"
edx_internal: True
COMMON_USER_INFO:
  - name: ${github_username}
    github: true
    type: admin
USER_CMD_PROMPT: '[$name_tag] '
COMMON_ENABLE_NEWRELIC_APP: $enable_newrelic
COMMON_ENABLE_DATADOG: $enable_datadog
FORUM_NEW_RELIC_ENABLE: $enable_newrelic
ENABLE_PERFORMANCE_COURSE: $performance_course
ENABLE_DEMO_TEST_COURSE: $demo_test_course
ENABLE_EDX_DEMO_COURSE: $edx_demo_course
EDXAPP_NEWRELIC_LMS_APPNAME: sandbox-${dns_name}-edxapp-lms
EDXAPP_NEWRELIC_CMS_APPNAME: sandbox-${dns_name}-edxapp-cms
EDXAPP_NEWRELIC_WORKERS_APPNAME: sandbox-${dns_name}-edxapp-workers
XQUEUE_NEWRELIC_APPNAME: sandbox-${dns_name}-xqueue
FORUM_NEW_RELIC_APP_NAME: sandbox-${dns_name}-forums
SANDBOX_USERNAME: $github_username
EDXAPP_ECOMMERCE_PUBLIC_URL_ROOT: "https://ecommerce-${deploy_host}"
EDXAPP_ECOMMERCE_API_URL: "https://ecommerce-${deploy_host}/api/v2"

ECOMMERCE_ECOMMERCE_URL_ROOT: "https://ecommerce-${deploy_host}"
ECOMMERCE_LMS_URL_ROOT: "https://${deploy_host}"
ECOMMERCE_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true

PROGRAMS_URL_ROOT: "https://programs-${deploy_host}"
PROGRAMS_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true
EOF
fi


if [[ $recreate == "true" ]]; then
    # vars specific to provisioning added to $extra-vars
    cat << EOF >> $extra_vars_file
dns_name: $dns_name
keypair: $keypair
instance_type: $instance_type
security_group: $security_group
ami: $ami
region: $region
zone: $zone
instance_tags:
    environment: $environment
    github_username: $github_username
    Name: $name_tag
    source: jenkins
    owner: $BUILD_USER
    instance_termination_time: $TERMINATION_DATE_TIME
    datadog: monitored
root_ebs_size: $root_ebs_size
name_tag: $name_tag
dns_zone: $dns_zone
rabbitmq_refresh: True
elb: $elb
EOF



    # run the tasks to launch an ec2 instance from AMI
    cat $extra_vars_file
    run_ansible edx_provision.yml -i inventory.ini $extra_var_arg --user ubuntu

    if [[ $server_type == "full_edx_installation" ]]; then
        # additional tasks that need to be run if the
        # entire edx stack is brought up from an AMI
        run_ansible rabbitmq.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
        run_ansible restart_supervisor.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
    fi
fi

declare -A deploy
roles="edxapp forum ecommerce programs notifier xqueue xserver ora discern certs demo testcourses"
for role in $roles; do
    deploy[$role]=${!role}
done

# If reconfigure was selected or if starting from an ubuntu 12.04 AMI
# run non-deploy tasks for all roles
if [[ $reconfigure == "true" || $server_type == "full_edx_installation_from_scratch" ]]; then
    cat $extra_vars_file
    run_ansible edx_continuous_integration.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
fi

if [[ $reconfigure != "true" && $server_type == "full_edx_installation" ]]; then
    # Run deploy tasks for the roles selected
    for i in $roles; do
        if [[ ${deploy[$i]} == "true" ]]; then
            cat $extra_vars_file
            run_ansible ${i}.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
        fi
    done
fi

# deploy the edx_ansible role
run_ansible edx_ansible.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
cat $sandbox_vars_file $extra_vars_file | grep -v -E "_version|migrate_db" > ${extra_vars_file}_clean
ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=${extra_vars_file}_clean dest=/edx/app/edx_ansible/server-vars.yml" -u ubuntu -b
ret=$?
if [[ $ret -ne 0 ]]; then
  exit $ret
fi

if [[ $run_oauth == "true" ]]; then
    # Setup the OAuth2 clients
    run_ansible oauth_client_setup.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
fi

# set the hostname
run_ansible set_hostname.yml -i "${deploy_host}," -e hostname_fqdn=${deploy_host} --user ubuntu

rm -f "$extra_vars_file"
rm -f ${extra_vars_file}_clean
