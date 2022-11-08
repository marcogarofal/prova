#! /bin/bash

function host_config()
{
controller=$(echo "$ip"     "controller")
sed -i "/127.0.0.1/a$controller" /etc/hosts
}

function install_stein_packages()
{
#Update packages
apt -y update

#NTP Installation
apt -y install chrony

#OpenStack Stein repository
add-apt-repository cloud-archive:stein -y

#Upgrade packages
apt -y update && apt -y dist-upgrade

#Installing OpenStack Client
apt -y install python3-openstackclient

#Installing chrony
apt -y install chrony

#Installing mariadb
apt -y install mariadb-server python-pymysql

#Installing rabbit-mq
apt -y install rabbitmq-server

#Installing memcached
apt -y install memcached python-memcache

#Installing Keystone
apt -y install keystone

#Installing swift
apt-get -y install swift swift-proxy python-swiftclient python-keystoneclient python-keystonemiddleware memcached
apt-get -y install xfsprogs rsync
apt-get -y install swift swift-account swift-container swift-object

#Installing Horizon
apt -y install openstack-dashboard
}

function configuring_db()
{

#copy preconfig file
cp ./conf_files/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf
sed -i -e  "s/^\(bind-address\s*=\).*/\1 $ip/" /etc/mysql/mariadb.conf.d/50-server.cnf

#Restart the database service
service mysql restart

#####Delete anonymous users and  SET plugin = mysql_native_password starts######

echo "UPDATE mysql.user SET Password=PASSWORD('$maria_db_root_password') WHERE User='root';" | mysql
echo "DELETE FROM mysql.user WHERE User='';" | mysql
echo "UPDATE mysql.user SET plugin = 'mysql_native_password' WHERE User = 'root';" | mysql
echo "FLUSH PRIVILEGES;" | mysql

#####Delete anonymous users and  SET plugin = 'mysql_native_password' ends######


#######Database and Database user Creation Starts#######

#keystone database
echo "CREATE DATABASE $keystone_db_name;" | $maria_db_connect
echo "GRANT ALL PRIVILEGES ON $keystone_db_name.* TO '$keystone_db_user'@'localhost' IDENTIFIED BY '$keystone_db_password';" | $maria_db_connect
echo "GRANT ALL PRIVILEGES ON $keystone_db_name.* TO '$keystone_db_user'@'%' IDENTIFIED BY '$keystone_db_password';" | $maria_db_connect
echo "FLUSH PRIVILEGES;" | $maria_db_connect

#######Database and Database user Creation ends#######

}

function chrony()
{
#copy preconfig file
cp ./conf_files/chrony.conf /etc/chrony/chrony.conf

#restart chrony
service chrony restart

# verify NTP synchronization
chronyc sources
}

function rabbitmq()
{
#Add the openstack user
rabbitmqctl add_user openstack RABBIT_PASS

#Permit configuration, write, and read access for the openstack user
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
}

function memcached()
{
#copy preconfig file
sed -i -e  "s/^\(-l\s*\).*/\1 $ip/" /etc/memcached.conf

#Restart the Memcached service
service memcached restart
}

function keystone()
{
#copy preconfig file
cp ./conf_files/keystone.conf /etc/keystone/keystone.conf


#Populating the Identity service database
su -s /bin/sh -c "keystone-manage db_sync" keystone

#Initialize Fernet key repositories
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

#Bootstrap the Identity service
keystone-manage bootstrap --bootstrap-password ADMIN_PASS \
  --bootstrap-admin-url http://controller:5000/v3/ \
  --bootstrap-internal-url http://controller:5000/v3/ \
  --bootstrap-public-url http://controller:5000/v3/ \
  --bootstrap-region-id RegionOne

#Restart the Apache service
export OS_USERNAME=admin
export OS_PASSWORD=Opst_stfth
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3


#Domain Creation
openstack domain create --description "An Example Domain" example

#Service project creation
openstack project create --domain default --description "Service Project" service

#demo project creation
openstack project create --domain default --description "Demo Project" myproject

#creating non-admin user
openstack user create --domain default --password MYUSER_PASS myuser

#creating my role
openstack role create myrole

#Add the myrole role to the myproject project and myuser user
openstack role add --project myproject --user myuser myrole

#Unset the temporary OS_AUTH_URL and OS_PASSWORD environment variable:
unset OS_AUTH_URL OS_PASSWORD

#As the admin user, request an authentication token
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default --os-user-domain-name Default \
  --os-project-name admin --os-username admin --os-password ADMIN_PASS token issue

#As the myuser user created in the previous, request an authentication token
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default --os-user-domain-name Default \
  --os-project-name myproject --os-username myuser --os-password MYUSER_PASS token issue
}

function swift_install()
{
#copy preconfig file
mkdir -p /etc/swift
cp ./conf_files/proxy-server.conf /etc/swift/proxy-server.conf
cp ./conf_files/proxy-server.conf /etc/swift/internal-client.conf
cp ./conf_files/rsyncd.conf /etc/rsyncd.conf
sed -i -e  's/^\(address\s*=\).*/\1 '$ip'/' /etc/rsyncd.conf
sed -i -e 's/RSYNC_ENABLE=false/RSYNC_ENABLE=true/g' /etc/default/rsync
service rsync start
cp ./conf_files/account-server.conf /etc/swift/account-server.conf
sed -i -e  's/^\(bind_ip\s*=\).*/\1 '$ip'/' /etc/swift/account-server.conf
cp ./conf_files/container-server.conf /etc/swift/container-server.conf
sed -i -e  's/^\(bind_ip\s*=\).*/\1 '$ip'/' /etc/swift/container-server.conf
cp ./conf_files/object-server.conf /etc/swift/object-server.conf
sed -i -e  's/^\(bind_ip\s*=\).*/\1 '$ip'/' /etc/swift/object-server.conf
cp ./conf_files/swift.conf /etc/swift/swift.conf

. admin-openrc
openstack user create --domain default --password SWIFT_PASS swift
openstack role add --project service --user swift admin
openstack service create --name swift --description "OpenStack Object Storage" object-store
openstack endpoint create --region RegionOne object-store public http://controller:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne object-store internal http://controller:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne object-store admin http://controller:8080/v1
mkfs.xfs -f /dev/$object_storage_disk
mkdir -p /srv/node/$object_storage_disk
echo "/dev/$object_storage_disk /srv/node/$object_storage_disk xfs noatime,nodiratime,nobarrier,logbufs=8 0 2" >> /etc/fstab
mount /srv/node/$object_storage_disk
service rsync start

#Ensure proper ownership of the mount point directory structure
chown -R swift:swift /srv/node

#Create the recon directory and ensure proper ownership of it
mkdir -p /var/cache/swift
chown -R root:swift /var/cache/swift
chmod -R 775 /var/cache/swift

#account ring creation
swift-ring-builder account.builder create 10 1 1
swift-ring-builder account.builder add --region 1 --zone 1 --ip $ip --port 6202 --device $object_storage_disk --weight 100
swift-ring-builder account.builder
swift-ring-builder account.builder rebalance

#container ring creation
swift-ring-builder container.builder create 10 1 1
swift-ring-builder container.builder add --region 1 --zone 1 --ip $ip --port 6201 --device $object_storage_disk --weight 100
swift-ring-builder container.builder
swift-ring-builder container.builder rebalance

#object ring creation
swift-ring-builder object.builder create 10 1 1
swift-ring-builder object.builder add --region 1 --zone 1 --ip $ip --port 6200 --device $object_storage_disk --weight 100
swift-ring-builder object.builder
swift-ring-builder object.builder rebalance

#Distribute ring configuration files
cp account.ring.gz container.ring.gz object.ring.gz /etc/swift

#On all nodes, ensure proper ownership of the configuration directory
chown -R root:swift /etc/swift
service memcached restart
service swift-proxy restart
swift-init all start

#Swift Verification
. admin-openrc
swift stat
}

function horizon()
{
#copy preconfig file
cp ./conf_files/local_settings.py /etc/openstack-dashboard/local_settings.py
cp ./conf_files/openstack-dashboard.conf /etc/apache2/conf-available/openstack-dashboard.conf
sed -i -e  "s/^\(OPENSTACK_HOST\s*=\).*/\1 '$ip'/" /etc/openstack-dashboard/local_settings.py
sed -i -e  "s/^\(\s*'LOCATION'\s*:\).*/\1 '$ip:11211', /" /etc/openstack-dashboard/local_settings.py

#Reload the web server configuration
service apache2 reload
}

#######MariaDB Credentials Starts ######
maria_db_user="root"

#selecting new passsword for maria db root user
maria_db_root_password="pyronoidninja"

maria_db_port="3306"
maria_db_connect="mysql -h localhost -u$maria_db_user -p$maria_db_root_password --port=$maria_db_port"

######MariaDB Credentials ends ######

####### Application databases with name and password Starts ########

# Keystone:
keystone_db_name="keystone"
keystone_db_user="keystone"
keystone_db_password="KEYSTONE_DBPASS"

####### Application databases with name and password ends ########

####Getting Provider NIC name and IP Address and object_storage_disk starts #####

ip=$(ip route get 8.8.8.8 | awk 'NR == 1 {print $7; exit }')
network_interface=$(ip route get 8.8.8.8 | awk 'NR == 1 {print $5 ; exit }')
object_storage_disk=$1;

####Getting Provider NIC name and IP Address and object_storage_disk ends #####

#######OpenStack Stein Installation Starts  ##############

host_config
install_stein_packages
#configuring_db
#chrony
#rabbitmq
#memcached
#keystone
swift_install
#horizon

#######OpenStack Stein Installation ends  ##############
