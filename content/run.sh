#!/bin/bash

# mysql variables
#MYSQL_HOST="${MYSQL_PORT_3306_TCP_ADDR}"
MYSQL_HOST="mysql"
MYSQL_CREATE_DB_CMD="CREATE DATABASE ${MYSQL_ICINGA_DB}; \
        GRANT SELECT, INSERT, UPDATE, DELETE, DROP, CREATE VIEW, INDEX, EXECUTE ON ${MYSQL_ICINGA_DB}.* TO '${MYSQL_ICINGA_USER}'@'%' IDENTIFIED BY '${MYSQL_ICINGA_PASSWORD}';"
		
# check linked mysql container
if [[ -z "${MYSQL_HOST}" ]]; then
  >&2 echo "no mysql database container find - please link a mysql/mariadb container using --link some-mariadb:mysql"
  exit 1
fi
while ! ping -c1 -w3 $MYSQL_HOST &>/dev/null; do 
  echo "ping to ${MYSQL_HOST} failed - waiting for mysql container"
done


# icinga2 features
echo "enabling icinga2 features"
# enable ido-mysql
if [[ -L /etc/icinga2/features-enabled/ido-mysql.conf ]]; then 
  echo "symlink for /etc/icinga2/features-enabled/ido-mysql.conf already exists"; 
  else 
    ln -s /etc/icinga2/features-available/ido-mysql.conf /etc/icinga2/features-enabled/ido-mysql.conf;
	# adjusting configuration
	sed -i "s/user.*/user = \"${MYSQL_ICINGA_USER}\",/g" /etc/icinga2/features-available/ido-mysql.conf
	sed -i "s/password.*/password = \"${MYSQL_ICINGA_PASSWORD}\",/g" /etc/icinga2/features-available/ido-mysql.conf
	sed -i "s/host.*/host = \"${MYSQL_HOST}\",/g" /etc/icinga2/features-available/ido-mysql.conf
	sed -i "s/database.*/database = \"${MYSQL_ICINGA_DB}\",/g" /etc/icinga2/features-available/ido-mysql.conf
	echo "enabled ido-mysql"
	
fi

# TODO - enable command?
# enable command
#if [[ -L /etc/icinga2/features-enabled/command.conf ]]; then 
#  echo "command feature already enabled"; 
#  else 
#    ln -s /etc/icinga2/features-available/command.conf /etc/icinga2/features-enabled/command.conf;
#fi


# enable api
if [[ ! -L /etc/icinga2/features-enabled/api.conf ]]; then 
  cat <<EOF >> /etc/icinga2/conf.d/api-users.conf

object ApiUser  "${API_USER}" {
  password =  "${API_PASSWORD}"
  permissions = [ "*" ]
}
EOF
  echo "enabled api"
  else 
    echo "symlink for /etc/icinga2/features-enabled/api.conf already exists"; 
fi

# create ca
if [[ ! -f /var/lib/icinga2/ca/ca.crt ]]; then
    echo "creating new ca"
    if ! icinga2 pki new-ca; then
		  >&2 echo "error creating new ca"
		  exit 1	  
	fi 
	else
	  "/var/lib/icinga2/ca/ca.crt already exists"
fi

#create new cert
if [[ ! -f /etc/icinga2/pki/${NODE_NAME}.crt ]]; then
  echo "creating new cert"
  if ! icinga2 pki new-cert --cn ${NODE_NAME} --key /etc/icinga2/pki/${NODE_NAME}.key --csr /etc/icinga2/pki/${NODE_NAME}.csr; then
	  >&2 echo "error creating new cert"
	  exit 1
  fi
  if ! icinga2 pki sign-csr --csr /etc/icinga2/pki/${NODE_NAME}.csr --cert /etc/icinga2/pki/${NODE_NAME}.crt; then   
    >&2 echo "error signing cert"
    exit 1
  fi
fi

# check if icinga database exists		
if mysqlshow -h ${MYSQL_HOST} --u root -p${MYSQL_ENV_MYSQL_ROOT_PASSWORD} ${MYSQL_ICINGA_DB}; then
  echo "found icinga2 mysql database in linked mysql container"
  else
    echo "mysql database ${MYSQL_DB_NAME} not found"
    # create database
    if mysql -h ${MYSQL_HOST} -u root -p${MYSQL_ENV_MYSQL_ROOT_PASSWORD} -e "${MYSQL_CREATE_DB_CMD}"; then
      echo "created database ${MYSQL_DB_NAME}"
	  if mysql -h ${MYSQL_HOST} -u root -p${MYSQL_ENV_MYSQL_ROOT_PASSWORD} ${MYSQL_ICINGA_DB} < /usr/share/icinga2-ido-mysql/schema/mysql.sql; then
	    echo "created icinga2 mysql database schema"
		else
		  >&2 echo "error creating icinga2 database schema"
		  exit 1
	  fi
      else
        >&2 echo "error creating database ${MYSQL_DB_NAME}"
		exit 1
    fi
fi


# preparing /var/run (icinga2 cannot start in foreground otherwise)
if [[ ! -e /var/run/icinga2/cmd ]]; then 
  echo "creating /var/run/icinga2 directory"
  mkdir -p /var/run/icinga2/cmd
  chown -R nagios:nagios /var/run/icinga2
fi

# start icinga2 in foreground
echo "starting icinga2..."
/usr/sbin/icinga2 daemon