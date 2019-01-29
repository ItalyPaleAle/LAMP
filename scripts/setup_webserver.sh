#!/bin/bash

# The MIT License (MIT)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -ex

lamp_on_azure_configs_json_path=${1}

. ./helper_functions.sh

get_setup_params_from_configs_json $lamp_on_azure_configs_json_path || exit 99

echo $glusterNode    >> /tmp/vars.txt
echo $glusterVolume  >> /tmp/vars.txt
echo $siteFQDN >> /tmp/vars.txt
echo $httpsTermination >> /tmp/vars.txt
echo $syslogServer >> /tmp/vars.txt
echo $webServerType >> /tmp/vars.txt
echo $dbServerType >> /tmp/vars.txt
echo $fileServerType >> /tmp/vars.txt
echo $storageAccountName >> /tmp/vars.txt
echo $storageAccountKey >> /tmp/vars.txt
echo $nfsVmName >> /tmp/vars.txt
echo $nfsByoIpExportPath >> /tmp/vars.txt
echo $htmlLocalCopySwitch >> /tmp/vars.txt

check_fileServerType_param $fileServerType

{
  # make sure the system does automatic update
  sudo apt-get -y update
  sudo apt-get -y install unattended-upgrades

  # install pre-requisites
  sudo apt-get -y install python-software-properties unzip rsyslog

  sudo apt-get -y install postgresql-client mysql-client git

  if [ $fileServerType = "gluster" ]; then
    #configure gluster repository & install gluster client
    sudo add-apt-repository ppa:gluster/glusterfs-3.10 -y
    sudo apt-get -y update
    sudo apt-get -y install glusterfs-client
  elif [ "$fileServerType" = "azurefiles" ]; then
    sudo apt-get -y install cifs-utils
  fi

  # install the base stack
  sudo apt-get -y install php php-cli php-curl php-zip php-pear php-mbstring php-dev mcrypt

  if [ "$webServerType" = "nginx" -o "$httpsTermination" = "VMSS" ]; then
    sudo apt-get -y install nginx
  fi

  if [ "$webServerType" = "apache" ]; then
    # install apache pacakges
    sudo apt-get -y install apache2 libapache2-mod-php
  else
    # for nginx-only option
    sudo apt-get -y install php-fpm
  fi

  # Moodle requirements
  sudo apt-get install -y graphviz aspell php-soap php-json php-redis php-bcmath php-gd php-pgsql php-mysql php-xmlrpc php-intl php-xml php-bz2
  if [ "$dbServerType" = "mssql" ]; then
    install_php_mssql_driver
  fi

  # PHP Version
  PhpVer=$(get_php_version)

  if [ $fileServerType = "gluster" ]; then
    # Mount gluster fs for /azlamp
    sudo mkdir -p /azlamp
    sudo chown www-data /azlamp
    sudo chmod 770 /azlamp
    sudo echo -e 'Adding Gluster FS to /etc/fstab and mounting it'
    setup_and_mount_gluster_share $glusterNode $glusterVolume /azlamp
  elif [ $fileServerType = "nfs" ]; then
    # mount NFS export (set up on controller VM--No HA)
    echo -e '\n\rMounting NFS export from '$nfsVmName':/azlamp on /azlamp and adding it to /etc/fstab\n\r'
    configure_nfs_client_and_mount $nfsVmName /azlamp /azlamp
  elif [ $fileServerType = "nfs-ha" ]; then
    # mount NFS-HA export
    echo -e '\n\rMounting NFS export from '$nfsHaLbIP':'$nfsHaExportPath' on /azlamp and adding it to /etc/fstab\n\r'
    configure_nfs_client_and_mount $nfsHaLbIP $nfsHaExportPath /azlamp
  elif [ $fileServerType = "nfs-byo" ]; then
    # mount NFS-BYO export
    echo -e '\n\rMounting NFS export from '$nfsByoIpExportPath' on /azlamp and adding it to /etc/fstab\n\r'
    configure_nfs_client_and_mount0 $nfsByoIpExportPath /azlamp
  else # "azurefiles"
    setup_and_mount_azure_files_share azlamp $storageAccountName $storageAccountKey
  fi

  # Configure syslog to forward
  cat <<EOF >> /etc/rsyslog.conf
\$ModLoad imudp
\$UDPServerRun 514
EOF
  cat <<EOF >> /etc/rsyslog.d/40-remote.conf
local1.*   @${syslogServer}:514
local2.*   @${syslogServer}:514
EOF
  service syslog restart

  if [ "$webServerType" = "nginx" -o "$httpsTermination" = "VMSS" ]; then
    # Build nginx config
    cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes 2;
pid /run/nginx.pid;

events {
	worker_connections 2048;
}

http {

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  types_hash_max_size 2048;
  client_max_body_size 0;
  proxy_max_temp_file_size 0;
  server_names_hash_bucket_size  128;
  fastcgi_buffers 16 16k; 
  fastcgi_buffer_size 32k;
  proxy_buffering off;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log;

  set_real_ip_from   127.0.0.1;
  real_ip_header      X-Forwarded-For;
  ssl_protocols TLSv1 TLSv1.1 TLSv1.2; # Dropping SSLv3, ref: POODLE
  ssl_prefer_server_ciphers on;

  gzip on;
  gzip_disable "msie6";
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.1;
  gzip_types text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript;
EOF
    if [ "$httpsTermination" != "None" ]; then
      cat <<EOF >> /etc/nginx/nginx.conf
  map \$http_x_forwarded_proto \$fastcgi_https {                                                                                          
    default \$https;                                                                                                                   
    http '';                                                                                                                          
    https on;                                                                                                                         
  }
EOF
    fi

    cat <<EOF >> /etc/nginx/nginx.conf
  log_format moodle_combined '\$remote_addr - \$upstream_http_x_moodleuser [\$time_local] '
                             '"\$request" \$status \$body_bytes_sent '
                             '"\$http_referer" "\$http_user_agent"';


  include /etc/nginx/conf.d/*.conf;
  include /etc/nginx/sites-enabled/*;
}
EOF
  fi # if [ "$webServerType" = "nginx" -o "$httpsTermination" = "VMSS" ];

  # Set up html dir local copy if specified
  if [ "$htmlLocalCopySwitch" = "true" ]; then
    mkdir -p /var/www/html
    rsync -av --delete /azlamp/html/. /var/www/html
    setup_html_local_copy_cron_job
  fi

  if [ "$webServerType" = "apache" ]; then
    # Configure Apache/php
    sed -i "s/Listen 80/Listen 81/" /etc/apache2/ports.conf
    a2enmod rewrite && a2enmod remoteip && a2enmod headers
  fi

  config_all_sites_on_vmss $htmlLocalCopySwitch $httpsTermination $webServerType

   # php config 
   if [ "$webServerType" = "apache" ]; then
     PhpIni=/etc/php/${PhpVer}/apache2/php.ini
   else
     PhpIni=/etc/php/${PhpVer}/fpm/php.ini
   fi
   sed -i "s/memory_limit.*/memory_limit = 512M/" $PhpIni
   sed -i "s/max_execution_time.*/max_execution_time = 18000/" $PhpIni
   sed -i "s/max_input_vars.*/max_input_vars = 100000/" $PhpIni
   sed -i "s/max_input_time.*/max_input_time = 600/" $PhpIni
   sed -i "s/upload_max_filesize.*/upload_max_filesize = 1024M/" $PhpIni
   sed -i "s/post_max_size.*/post_max_size = 1056M/" $PhpIni
   sed -i "s/;opcache.use_cwd.*/opcache.use_cwd = 1/" $PhpIni
   sed -i "s/;opcache.validate_timestamps.*/opcache.validate_timestamps = 1/" $PhpIni
   sed -i "s/;opcache.save_comments.*/opcache.save_comments = 1/" $PhpIni
   sed -i "s/;opcache.enable_file_override.*/opcache.enable_file_override = 0/" $PhpIni
   sed -i "s/;opcache.enable.*/opcache.enable = 1/" $PhpIni
   sed -i "s/;opcache.memory_consumption.*/opcache.memory_consumption = 256/" $PhpIni
   sed -i "s/;opcache.max_accelerated_files.*/opcache.max_accelerated_files = 8000/" $PhpIni
    
   # Remove the default site. Moodle is the only site we want
   rm -f /etc/nginx/sites-enabled/default
   if [ "$webServerType" = "apache" ]; then
     rm -f /etc/apache2/sites-enabled/000-default.conf
   fi

   if [ "$webServerType" = "nginx" -o "$httpsTermination" = "VMSS" ]; then
     # update startup script to wait for certificate in /azlamp mount
     setup_azlamp_mount_dependency_for_systemd_service nginx || exit 1
     # restart Nginx
     sudo service nginx restart 
   fi

   if [ "$webServerType" = "nginx" ]; then
     # fpm config - overload this 
     cat <<EOF > /etc/php/${PhpVer}/fpm/pool.d/www.conf
[www]
user = www-data
group = www-data
listen = /run/php/php${PhpVer}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 3000 
pm.start_servers = 20 
pm.min_spare_servers = 20 
pm.max_spare_servers = 30 
EOF

     # Restart fpm
     service php${PhpVer}-fpm restart
   fi

   if [ "$webServerType" = "apache" ]; then
      if [ "$htmlLocalCopySwitch" != "true" ]; then
        setup_azlamp_mount_dependency_for_systemd_service apache2 || exit 1
      fi
      sudo service apache2 restart
   fi

}  > /tmp/setup.log
