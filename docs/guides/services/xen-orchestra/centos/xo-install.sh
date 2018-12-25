#!/usr/bin/bash

# Ensure that the script is being run with root permissions
[ $EUID = 0 ] || { echo "This script needs to be run as root!"; }

if [ ! -x /bin/rpm ]; then
    echo Not running an Enterprise Linux based OS.
    echo Exiting.
    exit 1
fi

# Node.js variables
install_node=true
node_source="https://rpm.nodesource.com/setup_8.x"

# Yarn variables
install_yarn=true
yarn_source="https://dl.yarnpkg.com/rpm/yarn.repo"

# Xen Orchestra Variables
xo_branch="master"
xo_repo="http://github.com/vatesfr/xen-orchestra"
xo_dir="/opt"
xo_user="xo"
xo_user_group="xo"
xo_deps_repos=(
    'centos-release-xen'
    'epel-release'
    'https://forensics.cert.org/cert-forensics-tools-release-el7.rpm'
)
xo_deps=(
    'git'
    'libpng-devel'
    'xen-runtime'
    'lvm2'
    'qemu-img'
    'openssh'
    'libvhdi-tools'
    'fuse'
)
IFS='' read -r -d '' xo_unit <<EOF
[Unit]
Description=Xen Orchestra Xen Server Web Manager
After=network-online.target

[Service]
User=$xo_user
Group=$xo_user_group
WorkingDirectory=$xo_dir/xen-orchestra/packages/xo-server
ExecStart=/usr/bin/yarn start
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Redis Variables
install_redis=true
redis_source="http://download.redis.io/redis-stable.tar.gz"
redis_user="redis"
redis_user_group="redis"
redis_deps=(
    'gcc'
)
IFS='' read -r -d '' redis_unit <<EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
User=$redis_user
Group=$redis_user_group
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Check if a required command exists
check_command() {
    command -v $1 &>/dev/null || { echo >&2 "$2 is required but not installed. Aborting."; exit 1; }
}

# Check if a executable is requested and not installed
check_should_install() {
    if $1 && ! command -v $2 $>/dev/null; then
        return
    fi
    return 1
}

# Get dependencies by joining the programs's dependency array
get_deps() {
    local arr=("$@")
    local deps=$(IFS=$' '; echo "${arr[@]}")
    echo $deps
}

# Script arguments
# No arguments is suggested if a fresh OS is used
while [ ! $# -eq 0 ]; do
    case "$1" in
        --no-node)
            install_node=false
            check_command node "Node.js"
        ;;
        --no-redis)
            install_redis=false
            check_command redis-cli "Redis"
        ;;
        --no-yarn)
            install_yarn=false
            check_command yarn "Yarn"
        ;;
        --redis-user)
            redis_user=$2
        ;;
        --redis-user-group)
            redis_user_group=$2
        ;;
        --xo-branch)
            xo_branch=$2
        ;;
        --xo-install-dir)
            xo_dir=$2
        ;;
        --xo-user)
            xo_user=$2
        ;;
        --xo-user-group)
            xo_user_group=$2
        ;;
    esac
    shift
done

# Install Node Repository and add Node to dependencies
if check_should_install $install_node "node"; then
    curl -sL $node_source | bash -
    xo_deps+=('node')
fi

# Install Yarn Repository and add Yarn to dependencies
if check_should_install $install_yarn "yarn"; then
    curl -sL $yarn_source | tee /etc/yum.repos.d/yarn.repo
    xo_deps+=('yarn')
fi

# Build Redis from source
if check_should_install $install_redis "redis-cli"; then
    yum install -y $(get_deps ${redis_deps[@]})
    curl -sL $redis_source -o /tmp/redis-stable.tar.gz
    tar xzf /tmp/redis-stable.tar.gz -C /tmp
    make -s -C /tmp/redis-stable
    make -s install -C /tmp/redis-stable
    mkdir /etc/redis
    cp /tmp/redis-stable/redis.conf /etc/redis/redis.conf
    sed -i 's/supervised no/supervised systemd/' /etc/redis/redis.conf
    sed -i 's|dir \./|dir /var/lib/redis/|' /etc/redis/redis.conf
    groupadd -r $redis_user_group
    adduser -Mr -s /sbin/nologin -g $redis_user_group $redis_user
    mkdir /var/lib/redis
    chown $redis_user:$redis_user_group /var/lib/redis
    chmod 770 /var/lib/redis
    echo "$redis_unit" > /etc/systemd/system/redis.service
    systemctl daemon-reload
    systemctl enable --now redis.service
fi

# Build and install Xen Orchestra
yum install -y $(get_deps ${xo_deps_repos[@]})
yum update -y
yum install -y $(get_deps ${xo_deps[@]})
groupadd -r $xo_user_group
adduser -mr -s /sbin/nologin -g $xo_user_group $xo_user
git clone -b $xo_branch $xo_repo $xo_dir/xen-orchestra
chown -R $xo_user:$xo_user_group $xo_dir/xen-orchestra
# Uncomment if there are dependency issues or packages are not retrievable.
#rm $xo_dir/xen-orchestra/yarn.lock
mkdir /var/lib/xo-server
chown -R $xo_user:$xo_user_group /var/lib/xo-server
setcap cap_net_bind_service=+ep $(which node)
firewall-cmd --permanent --zone=public --add-port=80/tcp
firewall-cmd --reload
sudo -u $xo_user -s -- <<EOF
yarn --cwd $xo_dir/xen-orchestra
yarn --cwd $xo_dir/xen-orchestra build
cp $xo_dir/xen-orchestra/packages/xo-server/sample.config.yaml $xo_dir/xen-orchestra/packages/xo-server/.xo-server.yaml
sed -i "s|#'/': '/path/to/xo-web/dist/'|'/': '"${xo_dir}"/xen-orchestra/packages/xo-web/dist/'|" $xo_dir/xen-orchestra/packages/xo-server/.xo-server.yaml
EOF
echo "$xo_unit" > /etc/systemd/system/xo.service
systemctl daemon-reload
systemctl enable --now xo


#____________________________________

mkdir /run/xo-server
chown $xo_user:$xo_user_group /run/xo-server