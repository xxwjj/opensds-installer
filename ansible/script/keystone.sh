#!/usr/bin/env bash

# Copyright (c) 2018 Huawei Technologies Co., Ltd. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 'stack' user is just for install keystone through devstack

create_user(){
    if id "${STACK_USER_NAME}" &> /dev/null; then
        return
    fi
    sudo useradd -s /bin/bash -d "${STACK_HOME}" -m "${STACK_USER_NAME}"
    echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack
}


remove_user(){
    userdel "${STACK_USER_NAME}" -f -r
    rm /etc/sudoers.d/stack
}

devstack_local_conf(){
DEV_STACK_LOCAL_CONF=${DEV_STACK_DIR}/local.conf
cat > "$DEV_STACK_LOCAL_CONF" << DEV_STACK_LOCAL_CONF_DOCK
[[local|localrc]]
# use TryStack git mirror
GIT_BASE=$STACK_GIT_BASE

# If the "*_PASSWORD" variables are not set here you will be prompted to enter
# values for them by "stack.sh" and they will be added to "local.conf".
ADMIN_PASSWORD=$STACK_PASSWORD
DATABASE_PASSWORD=$STACK_PASSWORD
RABBIT_PASSWORD=$STACK_PASSWORD
SERVICE_PASSWORD=$STACK_PASSWORD

# Neither is set by default.
HOST_IP=$HOST_IP

# path of the destination log file.  A timestamp will be appended to the given name.
LOGFILE=\$DEST/logs/stack.sh.log

# Old log files are automatically removed after 7 days to keep things neat.  Change
# the number of days by setting "LOGDAYS".
LOGDAYS=2

ENABLED_SERVICES=mysql,key
# Using stable/queens branches
# ---------------------------------
KEYSTONE_BRANCH=$STACK_BRANCH
KEYSTONECLIENT_BRANCH=$STACK_BRANCH
DEV_STACK_LOCAL_CONF_DOCK
chown stack:stack "$DEV_STACK_LOCAL_CONF"
}

opensds_conf() {
cat >> "$OPENSDS_CONFIG_DIR/opensds.conf" << OPENSDS_GLOBAL_CONFIG_DOC


[keystone_authtoken]
memcached_servers = $HOST_IP:11211
signing_dir = /var/cache/opensds
cafile = /opt/stack/data/ca-bundle.pem
auth_uri = http://$HOST_IP/identity
project_domain_name = Default
project_name = service
user_domain_name = Default
password = $STACK_PASSWORD
username = $OPENSDS_SERVER_NAME
auth_url = http://$HOST_IP/identity
auth_type = password

OPENSDS_GLOBAL_CONFIG_DOC

cp "$ANSIBLE_CONF_DIR/policy.json" "$OPENSDS_CONFIG_DIR"
}

multicloud_conf() {
    local compose_file=/opt/opensds-gelato-linux-amd64/docker-compose.yml
    sed -i "s,OS_AUTH_AUTHSTRATEGY:.*$,OS_AUTH_AUTHSTRATEGY: \"keystone\"," $compose_file
    sed -i "s,OS_AUTH_URL:.*$,OS_AUTH_URL: \"http://$HOST_IP/identity\"," $compose_file
    sed -i "s,OS_USERNAME:.*$,OS_USERNAME: \"$MULTICLOUD_SERVER_NAME\"," $compose_file
    sed -i "s,OS_PASSWORD:.*$,OS_PASSWORD: \"$MULTICLOUD_PASSWORD\"," $compose_file
}
create_user_and_endpoint_for_opensds(){
    . "$DEV_STACK_DIR/openrc" admin admin
    openstack user create --domain default --password "$STACK_PASSWORD" "$OPENSDS_SERVER_NAME"
    openstack role add --project service --user "$OPENSDS_SERVER_NAME" admin
    openstack group create service
    openstack group add user service "$OPENSDS_SERVER_NAME"
    openstack role add service --project service --group service
    openstack group add user admins admin
    openstack service create --name "opensds$OPENSDS_VERSION" --description "OpenSDS Block Storage" "opensds$OPENSDS_VERSION"
    openstack endpoint create --region RegionOne "opensds$OPENSDS_VERSION" public "http://$HOST_IP:50040/$OPENSDS_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "opensds$OPENSDS_VERSION" internal "http://$HOST_IP:50040/$OPENSDS_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "opensds$OPENSDS_VERSION" admin "http://$HOST_IP:50040/$OPENSDS_VERSION/%(tenant_id)s"
}

create_user_and_endpoint_for_multicloud(){
    . "$DEV_STACK_DIR/openrc" admin admin
    if openstack user show $MULTICLOUD_SERVER_NAME &>/dev/null; then
        return 
    fi
    openstack user create --domain default --password "$STACK_PASSWORD" "$MULTICLOUD_SERVER_NAME"
    openstack role add --project service --user "$MULTICLOUD_SERVER_NAME" admin
    openstack group create service
    openstack group add user service "$MULTICLOUD_SERVER_NAME"
    openstack role add service --project service --group service
    openstack group add user admins admin
    openstack service create --name "multicloud$MULTICLOUD_VERSION" --description "Multi-cloud Block Storage" "multicloud$MULTICLOUD_VERSION"
    openstack endpoint create --region RegionOne "multicloud$MULTICLOUD_VERSION" public "http://$HOST_IP:8089/$MULTICLOUD_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "multicloud$MULTICLOUD_VERSION" internal "http://$HOST_IP:8089/$MULTICLOUD_VERSION/%(tenant_id)s"
    openstack endpoint create --region RegionOne "multicloud$MULTICLOUD_VERSION" admin "http://$HOST_IP:8089/$MULTICLOUD_VERSION/%(tenant_id)s"
}

delete_redundancy_data() {
    . "$DEV_STACK_DIR/openrc" admin admin
    openstack project delete demo
    openstack project delete alt_demo
    openstack project delete invisible_to_admin
    openstack user delete demo
    openstack user delete alt_demo
}

download_code(){
    if [ ! -d "${DEV_STACK_DIR}" ];then
        git clone "${STACK_GIT_BASE}/openstack-dev/devstack.git" -b "${STACK_BRANCH}" "${DEV_STACK_DIR}"
        chown stack:stack -R "${DEV_STACK_DIR}"
    fi
}


install(){
    create_user
    download_code
    # If keystone is ready to start, there is no need continue next step.
    if wait_for_url "http://$HOST_IP/identity" "keystone" 0.25 4; then
        return
    fi
    devstack_local_conf
    cd "${DEV_STACK_DIR}"
    su "$STACK_USER_NAME" -c "${DEV_STACK_DIR}/stack.sh" >/dev/null
    delete_redundancy_data
}

uninstall(){
    su "$STACK_USER_NAME" -c "${DEV_STACK_DIR}/clean.sh" >/dev/null
    su "$STACK_USER_NAME" -c "${DEV_STACK_DIR}/unstack.sh" >/dev/null
}

uninstall_purge() {
    rm "${STACK_HOME:?'STACK_HOME must be defined and cannot be empty'}/*" -rf
    remove_user
}

config_opensds() {
    opensds_conf
    create_user_and_endpoint_for_opensds
}

config_multicloud() {
    multicloud_conf
    create_user_and_endpoint_for_multicloud
}

# ***************************
TOP_DIR=$(cd $(dirname "$0") && pwd)

# OpenSDS configuration directory
OPENSDS_CONFIG_DIR=${OPENSDS_CONFIG_DIR:-/etc/opensds}

source "$TOP_DIR/util.sh"
source "$TOP_DIR/sdsrc"

case "$# $1" in
    "1 install")
    echo "Starting install keystone..."
    install
    ;;
    "1 uninstall")
    echo "Starting uninstall keystone..."
    uninstall
    ;;
    "1 config")
    [[ X$2 != Xopensds || X$2 != Xmulticloud ]] && echo "config type must be opensds or multicloud" && exit
    echo "Starting config $2 ..."
    config_$2
    ;;
    "1 uninstall_purge")
    echo "Starting uninstall purge keystone..."
    uninstall_purge
    ;;
     *)
    echo "Usage: $(basename $0) <install|config|uninstall|uninstall_purge> [parameters ...]"
    exit 1
    ;;
esac

