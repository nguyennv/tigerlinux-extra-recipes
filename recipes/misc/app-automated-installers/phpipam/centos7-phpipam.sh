#!/bin/bash
#
# Reynaldo R. Martinez P.
# tigerlinux@gmail.com
# http://tigerlinux.github.io
# https://github.com/tigerlinux
# PHPIPAM Server Installation Script
# Rel 1.2
# For usage on centos7 64 bits machines.
#

PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
OSFlavor='unknown'
lgfile="/var/log/phpipam-server-automated-installer.log"
credfile="/root/phpipam-server-credentials.txt"
echo "Start Date/Time: `date`" &>>$lgfile

if [ -f /etc/centos-release ]
then
	OSFlavor='centos-based'
	yum clean all
	yum -y install coreutils grep curl wget redhat-lsb-core net-tools \
	git findutils iproute grep openssh sed gawk openssl which xz bzip2 \
	util-linux procps-ng which lvm2 sudo hostname &>>$lgfile
else
	echo "Nota a centos machine. Aborting!." &>>$lgfile
	echo "End Date/Time: `date`" &>>$lgfile
	exit 0
fi

amicen=`lsb_release -i|grep -ic centos`
crel7=`lsb_release -r|awk '{print $2}'|grep ^7.|wc -l`
if [ $amicen != "1" ] || [ $crel7 != "1" ]
then
	echo "This is NOT a Centos 7 machine. Aborting !" &>>$lgfile
	echo "End Date/Time: `date`" &>>$lgfile
	exit 0
fi

kr64inst=`uname -p 2>/dev/null|grep x86_64|head -n1|wc -l`

if [ $kr64inst != "1" ]
then
	echo "Not a 64 bits machine. Aborting !" &>>$lgfile
	echo "End Date/Time: `date`" &>>$lgfile
	exit 0
fi

export mariadbpass=`openssl rand -hex 10`
export ipamdbpass=`openssl rand -hex 10`
export mariadbip='127.0.0.1'

cpus=`lscpu -a --extended|grep -ic yes`
instram=`free -m -t|grep -i mem:|awk '{print $2}'`
avusr=`df -k --output=avail /usr|tail -n 1`
avvar=`df -k --output=avail /var|tail -n 1`

if [ $cpus -lt "1" ] || [ $instram -lt "480" ] || [ $avusr -lt "5000000" ] || [ $avvar -lt "5000000" ]
then
	echo "Not enough hardware for a PHPIPAM Server. Aborting!" &>>$lgfile
	echo "End Date/Time: `date`" &>>$lgfile
	exit 0
fi

setenforce 0
sed -r -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
sed -r -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
yum -y install firewalld &>>$lgfile
systemctl enable firewalld
systemctl restart firewalld
firewall-cmd --zone=public --add-service=http --permanent
firewall-cmd --zone=public --add-service=https --permanent
firewall-cmd --zone=public --add-service=ssh --permanent
firewall-cmd --reload

echo "net.ipv4.tcp_timestamps = 0" > /etc/sysctl.d/10-disable-timestamps.conf
sysctl -p /etc/sysctl.d/10-disable-timestamps.conf

if [ `grep -c swapfile /etc/fstab` == "0" ]
then
	myswap=`free -m -t|grep -i swap:|awk '{print $2}'`
	if [ $myswap -lt 2000 ]
	then
		fallocate -l 2G /swapfile
		chmod 600 /swapfile
		mkswap /swapfile
		swapon /swapfile
		echo '/swapfile none swap sw 0 0' >> /etc/fstab
	fi
fi

# Kill packet.net repositories if detected here.
yum -y install yum-utils &>>$lgfile
repotokill=`yum repolist|grep -i ^packet|cut -d/ -f1`
for myrepo in $repotokill
do
	echo "Disabling repo: $myrepo" &>>$lgfile
	yum-config-manager --disable $myrepo &>>$lgfile
done


yum -y install epel-release
yum -y install device-mapper-persistent-data

cat <<EOF >/etc/yum.repos.d/mariadb101.repo
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.1/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF

yum -y update --exclude=kernel* &>>$lgfile
yum -y install MariaDB MariaDB-server MariaDB-client galera crudini &>>$lgfile

cat <<EOF >/etc/my.cnf.d/server-lemp.cnf
[mysqld]
binlog_format = ROW
default-storage-engine = innodb
innodb_autoinc_lock_mode = 2
query_cache_type = 1
query_cache_size = 8388608
query_cache_limit = 1048576
bind-address = $mariadbip
max_allowed_packet = 1024M
max_connections = 1000
innodb_doublewrite = 1
innodb_log_file_size = 100M
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table
EOF

mkdir -p /etc/systemd/system/mariadb.service.d/
cat <<EOF >/etc/systemd/system/mariadb.service.d/limits.conf
[Service]
LimitNOFILE=65535
EOF

cat <<EOF >/etc/security/limits.d/10-mariadb.conf
mysql hard nofile 65535
mysql soft nofile 65535
EOF

systemctl --system daemon-reload

systemctl enable mariadb.service
systemctl start mariadb.service

cat<<EOF >/root/os-db.sql
UPDATE mysql.user SET Password=PASSWORD('$mariadbpass') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '$mariadbpass' WITH GRANT OPTION;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS phpipam default character set utf8;
GRANT ALL ON phpipam.* TO 'phpipam'@'%' IDENTIFIED BY '$ipamdbpass';
GRANT ALL ON phpipam.* TO 'phpipam'@'127.0.0.1' IDENTIFIED BY '$ipamdbpass';
GRANT ALL ON phpipam.* TO 'phpipam'@'localhost' IDENTIFIED BY '$ipamdbpass';
FLUSH PRIVILEGES;
EOF

mysql < /root/os-db.sql

cat<<EOF >/root/.my.cnf
[client]
user = "root"
password = "$mariadbpass"
host = "localhost"
EOF

chmod 0600 /root/.my.cnf

rm -f /root/os-db.sql

echo "Database credentials:" > $credfile
echo "User: root" >> $credfile
echo "Password: $mariadbpass" >> $credfile
echo "Listen IP: $mariadbip" >> $credfile
echo "IPAM Database: phpipam" >> $credfile
echo "IPAM DB User: phpipam" >> $credfile
echo "IPAM DB User Password: $ipamdbpass" >> $credfile
echo "IPAM User: Admin" >> $credfile
echo "IPAM Initial password: ipamadmin" >> $credfile
echo "URL: http://YOUR_SERVER_IP" >> $credfile
echo "URL: httpS://YOUR_SERVER_IP" >> $credfile

yum -y install https://mirror.webtatic.com/yum/el7/webtatic-release.rpm
yum -y update --exclude=kernel* &>>$lgfile
yum -y erase php-common
yum -y install nginx php71w php71w-opcache php71w-pear \
php71w-pdo php71w-xml php71w-pdo_dblib php71w-mbstring \
php71w-mysqlnd php71w-mcrypt php71w-fpm php71w-bcmath \
php71w-gd php71w-cli php71w-json php71w-ldap &>>$lgfile

crudini --set /etc/php.ini PHP upload_max_filesize 100M
crudini --set /etc/php.ini PHP post_max_size 100M
mytimezone=`timedatectl status|grep -i "time zone:"|cut -d: -f2|awk '{print $1}'`

if [ -f /usr/share/zoneinfo/$mytimezone ]
then
	crudini --set /etc/php.ini PHP date.timezone "$mytimezone"
else
	crudini --set /etc/php.ini PHP date.timezone "UTC"
fi

mkdir -p /var/lib/php/session
chown -R nginx:nginx /var/lib/php/session
sed -r -i 's/apache/nginx/g' /etc/php-fpm.d/www.conf

systemctl enable php-fpm
systemctl restart php-fpm

openssl dhparam -out /etc/nginx/dhparams.pem 2048 &>>$lgfile

cat <<EOF>/etc/nginx/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
 worker_connections 1024;
}

http {
 log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
 '\$status \$body_bytes_sent "\$http_referer" '
 '"\$http_user_agent" "\$http_x_forwarded_for"';

 access_log  /var/log/nginx/access.log  main;
 client_max_body_size 100M;

 sendfile            on;
 tcp_nopush          on;
 tcp_nodelay         on;
 keepalive_timeout   65;
 types_hash_max_size 2048;

 include             /etc/nginx/mime.types;
 default_type        application/octet-stream;

 include /etc/nginx/conf.d/*.conf;

 server {
  listen       80 default_server;
  listen       [::]:80 default_server;
  server_name  _;
  #Uncomment the following line if you want to redirect your http site
  #to the https one.
  #return 301 https://\$server_name\$request_uri;
  root /usr/share/nginx/html;

  # Load configuration files for the default server block.
  include /etc/nginx/default.d/*.conf;

  location /css {
    try_files \$uri \$uri/ =404;
  }

  location /js {
    try_files \$uri \$uri/ =404;
  }

  location / {
    index index.php;
    rewrite ^/login/dashboard/?\$ /dashboard/ redirect;
    rewrite ^/logout/dashboard/?\$ /dashboard/ redirect;
    rewrite ^/tools/search/(.*)\$ /index.php?page=tools&section=search&ip=\$1 last;
    rewrite ^/(.*)/(.*)/(.*)/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2&subnetId=\$3&sPage=\$4&ipaddrid=\$5 last;
    rewrite ^/(.*)/(.*)/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2&subnetId=\$3&sPage=\$4 last;
    rewrite ^/(.*)/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2&subnetId=\$3 last;
    rewrite ^/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2 last;
    rewrite ^/([^/]+)/? /index.php?page=\$1 last;
  }

  location /api {
    rewrite ^/api/(.*)/(.*)/(.*)/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2&id=\$3&id2=\$4&id3=\$5 last;
    rewrite ^/api/(.*)/(.*)/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2&id=\$3&id2=\$4 last;
    rewrite ^/api/(.*)/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2&id=\$3 last;
    rewrite ^/api/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2 last;
    rewrite ^/api/(.*) /api/index.php?app_id=\$1 last;
  }

  location ~ ^/.+\.php {
    fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_index  index.php;
    fastcgi_split_path_info ^(.+\.php)(/?.+)\$;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
    fastcgi_param PATH_TRANSLATED \$document_root\$fastcgi_path_info;
    include fastcgi_params;
    fastcgi_pass 127.0.0.1:9000;
  }
 }

 server {
  listen 443 ssl http2 default_server;
  listen [::]:443 ssl http2 default_server;
  server_name  _;
  root /usr/share/nginx/html;

  ssl_certificate "/etc/pki/nginx/server.crt";
  ssl_certificate_key "/etc/pki/nginx/private/server.key";

  include /etc/nginx/default.d/*.conf;

  location /css {
    try_files \$uri \$uri/ =404;
  }

  location /js {
    try_files \$uri \$uri/ =404;
  }

  location / {
    index index.php;
    rewrite ^/login/dashboard/?\$ /dashboard/ redirect;
    rewrite ^/logout/dashboard/?\$ /dashboard/ redirect;
    rewrite ^/tools/search/(.*)\$ /index.php?page=tools&section=search&ip=\$1 last;
    rewrite ^/(.*)/(.*)/(.*)/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2&subnetId=\$3&sPage=\$4&ipaddrid=\$5 last;
    rewrite ^/(.*)/(.*)/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2&subnetId=\$3&sPage=\$4 last;
    rewrite ^/(.*)/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2&subnetId=\$3 last;
    rewrite ^/(.*)/([^/]+)/? /index.php?page=\$1&section=\$2 last;
    rewrite ^/([^/]+)/? /index.php?page=\$1 last;
  }
 
  location /api {
    index index.php;
    rewrite ^/api/(.*)/(.*)/(.*)/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2&id=\$3&id2=\$4&id3=\$5 last;
    rewrite ^/api/(.*)/(.*)/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2&id=\$3&id2=\$4 last;
    rewrite ^/api/(.*)/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2&id=\$3 last;
    rewrite ^/api/(.*)/(.*) /api/index.php?app_id=\$1&controller=\$2 last;
    rewrite ^/api/(.*) /api/index.php?app_id=\$1 last;
  }

  location ~ ^/.+\.php {
    fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_index  index.php;
    fastcgi_split_path_info ^(.+\.php)(/?.+)\$;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
    fastcgi_param PATH_TRANSLATED \$document_root\$fastcgi_path_info;
    include fastcgi_params;
    fastcgi_pass 127.0.0.1:9000;
  }
 }
}
EOF


cat <<EOF>/etc/nginx/default.d/sslconfig.conf
ssl_session_cache shared:SSL:1m;
ssl_session_timeout  10m;
ssl_prefer_server_ciphers on;
ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:!DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';
ssl_dhparam /etc/nginx/dhparams.pem;
EOF

mkdir -p /etc/pki/nginx
mkdir -p /etc/pki/nginx/private

openssl req -x509 -batch -nodes -days 365 -newkey rsa:2048 -keyout /etc/pki/nginx/private/server.key -out /etc/pki/nginx/server.crt &>>$lgfile

chmod 0600 /etc/pki/nginx/private/server.key
chown nginx.nginx /etc/pki/nginx/private/server.key

systemctl enable nginx

mv /usr/share/nginx/html /usr/share/nginx/html-old
git clone https://github.com/phpipam/phpipam.git /usr/share/nginx/html
cd /usr/share/nginx/html
git checkout 1.3
cd /
chown -R nginx.nginx /usr/share/nginx/html
find /usr/share/nginx/html -name "*" -type f -exec chmod 644 "{}" ";"
find /usr/share/nginx/html -name "*" -type d -exec chmod 755 "{}" ";"

# mysql phpipam < /usr/share/nginx/html/db/SCHEMA.sql
# mysql -u root -h 127.0.0.1 -P 3306 -p`grep password /root/.my.cnf |cut -d\" -f2` phpipam < /usr/share/nginx/html/db/SCHEMA.sql
mysql -u root --protocol=socket --socket=/var/lib/mysql/mysql.sock -p`grep password /root/.my.cnf |cut -d\" -f2` phpipam < /usr/share/nginx/html/db/SCHEMA.sql

cp /usr/share/nginx/html/config.dist.php /usr/share/nginx/html/config.php
chown nginx.nginx /usr/share/nginx/html/config.php

rm -rf /usr/share/nginx/html/.git*


sed -r -i "s/phpipamadmin/$ipamdbpass/g" /usr/share/nginx/html/config.php
sed -r -i 's/localhost/127.0.0.1/g' /usr/share/nginx/html/config.php

yum -y install python2-certbot-nginx &>>$lgfile

cat<<EOF>/etc/cron.d/letsencrypt-renew-crontab
#
#
# Letsencrypt automated renewal
#
# Every day at 01:30am
#
30 01 * * * root /usr/bin/certbot renew > /var/log/le-renew.log 2>&1
#
EOF

systemctl restart php-fpm nginx crond

finalcheck=`curl --write-out %{http_code} --silent --output /dev/null http://127.0.0.1/|grep -c 302`

if [ $finalcheck == "1" ]
then
	echo "Ready. Your PHPIPAM Server is ready. See your database credentiales at $credfile" &>>$lgfile
	echo "" &>>$lgfile
	cat $credfile &>>$lgfile
	echo "End Date/Time: `date`" &>>$lgfile
else
	echo "PHPIPAM Server install failed" &>>$lgfile
	echo "End Date/Time: `date`" &>>$lgfile
fi
