#version=DEVEL
# System authorization information
auth --enableshadow --passalgo=sha512
# Use CDROM installation media
cdrom
# Use text mode install
text
# Firewall configuration
firewall --enabled --service=ssh
firstboot --disable
ignoredisk --only-use=sda
# Keyboard layouts
keyboard --vckeymap=gb --xlayouts='gb'
# System language
lang en_GB.UTF-8

# Network information
#network  --bootproto=dhcp --device=link --activate
network  --bootproto=dhcp --device=enp0s3 --onboot=off --ipv6=auto --no-activate
network  --hostname=localhost.localdomain
# Reboot after installation
reboot
repo --name="Server-HighAvailability" --baseurl=file:///run/install/repo/addons/HighAvailability
repo --name="Server-ResilientStorage" --baseurl=file:///run/install/repo/addons/ResilientStorage
# Root password
rootpw --iscrypted nope
# SELinux configuration
selinux --enforcing
# System services
services --disabled="kdump,rhsmcertd" --enabled="network,sshd,rsyslog,chronyd"
# Do not configure the X Window System
skipx
# System timezone
timezone Europe/London --isUtc
# System bootloader configuration
bootloader --append="console=ttyS0,115200n8 console=tty0 net.ifnames=0 rd.blacklist=nouveau nvme_core.io_timeout=4294967295 crashkernel=auto" --location=mbr --timeout=1 --boot-drive=sda
# Disk partitioning information
part / --fstype="xfs" --ondisk=sda --grow
part biosboot --fstype="biosboot" --ondisk=sda --size=1

user --name=ec2-user
sshkey --username=ec2-user "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFo/EwRnoEZqES2CQNkik5wsXERnOytHIoGuVtLsjzbhL4ybc13rsXeh9YaqxtbCEYfKftk6SITSNuk2rH38eOtTPFpayuek1IqQStVm+O3eb4VLIJ6LjupCJ6HNyP6BGm5yoJnaQHxQwhQql3lpUqVujVB46ikbOTxWuUw19puKCOKp4AzRlSQjTm7O+8/qoQnG4LZ93JvK6Nn6rg0uTGiyHIURBivdoQXZ2j0lZmfZdXMhYeNHbOr73qZEP1lvp3O9iPsJuZFrX+VR7FyI+wYZ4tp0TiikYLYvchEvhL0MAYc8PExJYEDfmyMhqnaBijNcB+ejNo+ho4JMrznmZh cosmin@cosmin-ubuntu-workstation"

%pre --erroronfail
/usr/sbin/parted -s /dev/sda mklabel gpt
%end

%post --nochroot
/sbin/sgdisk -t 2:8300 -p /dev/sda
%end

%post --erroronfail

# workaround anaconda requirements
passwd -d root
passwd -l root

/bin/echo "ec2-user        ALL=(ALL)       NOPASSWD: ALL" >> /etc/sudoers

subscription-manager register --activationkey my-rhel-activation-key --org 7008027

# Create grub.conf for EC2. This used to be done by appliance creator but
# anaconda doesn't do it. And, in case appliance-creator is used, we're
# overriding it here so that both cases get the exact same file.
# Note that the console line is different -- that's because EC2 provides
# different virtual hardware, and this is a convenient way to act differently
echo -n "Creating grub.conf for pvgrub"
rootuuid=$( awk '$2=="/" { print $1 };'  /etc/fstab )
mkdir /boot/grub
echo -e 'default=0\ntimeout=0\n\n' > /boot/grub/grub.conf
for kv in $( ls -1v /boot/vmlinuz* |grep -v rescue |sed s/.*vmlinuz-//  ); do
  echo "title Red Hat Enterprise Linux 7 ($kv)" >> /boot/grub/grub.conf
  echo -e "\troot (hd0)" >> /boot/grub/grub.conf
  echo -e "\tkernel /boot/vmlinuz-$kv ro root=$rootuuid console=hvc0 LANG=en_US.UTF-8" >> /boot/grub/grub.conf
  echo -e "\tinitrd /boot/initramfs-$kv.img" >> /boot/grub/grub.conf
  echo
done

# setup systemd to boot to the right runlevel
echo -n "Setting default runlevel to multiuser text mode"
rm -f /etc/systemd/system/default.target
ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
echo .

# this is installed by default but we don't need it in virt
echo "Removing linux-firmware package."
yum -C -y --noplugins remove linux-firmware

# Remove firewalld; it is required to be present for install/image building.
echo "Removing firewalld."
yum -C -y --noplugins remove firewalld --setopt="clean_requirements_on_remove=1"

echo -n "Network fixes"
# initscripts don't like this file to be missing.
cat > /etc/sysconfig/network << EOF
NETWORKING=yes
NOZEROCONF=yes
EOF

# For cloud images, 'eth0' _is_ the predictable device name, since
# we don't want to be tied to specific virtual (!) hardware
rm -f /etc/udev/rules.d/70*
ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules

# simple eth0 config, again not hard-coded to the build hardware
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
USERCTL="yes"
PEERDNS="yes"
IPV6INIT="no"
EOF

# generic localhost names
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

EOF
echo .

cat <<EOL > /etc/sysconfig/kernel
# UPDATEDEFAULT specifies if new-kernel-pkg should make
# new kernels the default
UPDATEDEFAULT=yes

# DEFAULTKERNEL specifies the default kernel package type
DEFAULTKERNEL=kernel
EOL

# make sure firstboot doesn't start
echo "RUN_FIRSTBOOT=NO" > /etc/sysconfig/firstboot

echo "Cleaning old yum repodata."
yum --noplugins clean all
truncate -c -s 0 /var/log/yum.log

echo "Fixing SELinux contexts."
touch /var/log/cron
touch /var/log/boot.log
mkdir -p /var/cache/yum
/usr/sbin/fixfiles -R -a restore

# remove these for ec2 debugging
sed -i -e 's/ rhgb quiet//' /boot/grub/grub.conf

# enable resizing on copied AMIs
echo 'install_items+=" sgdisk "' > /etc/dracut.conf.d/sgdisk.conf

cat /dev/null > /etc/machine-id

# also remove all anaconda logs from /var/log/anaconda
rm -rf /var/log/anaconda/*

# Setup the correct temp filesystems
echo 'tmpfs   /tmp    tmpfs   defaults,noexec,nosuid,nodev 0   0
tmpfs      /dev/shm    tmpfs   defaults,noexec,nodev,nosuid,seclabel   0 0' >> /etc/fstab

# Setup iptables although most likely it will not be used
echo"# Generated during the kickstart
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -s 127.0.0.0/8 -j DROP
-A INPUT -p tcp -m state --state ESTABLISHED -j ACCEPT
-A INPUT -p udp -m state --state ESTABLISHED -j ACCEPT
-A INPUT -p icmp -m state --state ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --dport 68 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --dport 123 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --dport 323 -m state --state NEW -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p tcp -m state --state NEW,ESTABLISHED -j ACCEPT
-A OUTPUT -p udp -m state --state NEW,ESTABLISHED -j ACCEPT
-A OUTPUT -p icmp -m state --state NEW,ESTABLISHED -j ACCEPT
COMMIT" > /etc/sysconfig/iptables
chmod 0600 /etc/sysconfig/iptables

echo"# Generated during the kickstart
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -s ::1/128 -j DROP
-A INPUT -p tcp -m state --state ESTABLISHED -j ACCEPT
-A INPUT -p udp -m state --state ESTABLISHED -j ACCEPT
-A INPUT -p icmp -m state --state ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --dport 68 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --dport 123 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --dport 323 -m state --state NEW -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p tcp -m state --state NEW,ESTABLISHED -j ACCEPT
-A OUTPUT -p udp -m state --state NEW,ESTABLISHED -j ACCEPT
-A OUTPUT -p icmp -m state --state NEW,ESTABLISHED -j ACCEPT
COMMIT" > /etc/sysconfig/ip6tables
chmod 0600 /etc/sysconfig/ip6tables

%end

%packages
@^minimal
@core
chrony
kexec-tools
-NetworkManager
-aic94xx-firmware
-alsa-firmware
-alsa-lib
-alsa-tools-firmware
-biosdevname
-iprutils
-ivtv-firmware
-iwl100-firmware
-iwl1000-firmware
-iwl105-firmware
-iwl135-firmware
-iwl2000-firmware
-iwl2030-firmware
-iwl3160-firmware
-iwl3945-firmware
-iwl4965-firmware
-iwl5000-firmware
-iwl5150-firmware
-iwl6000-firmware
-iwl6000g2a-firmware
-iwl6000g2b-firmware
-iwl6050-firmware
-iwl7260-firmware
-libertas-sd8686-firmware
-libertas-sd8787-firmware
-libertas-usb8388-firmware
-plymouth


%end

%addon com_redhat_kdump --enable --reserve-mb='auto'

%end

