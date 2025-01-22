## For AWS
## Launch new RH9 instance without LVM with 20G root
## 
## Repartition:
## https://github.com/mntbighker/rhel9-disastig-partition
##
# 90G
# part /boot # 500M
# part /boot/efi # 100M
# lv_root # 10G
# lv_var # 5G
# lv_log # 5G
# lv_audit # 3G
# lv_tmp # 3G
# lv_opt # 40G
# lv_home # 7G

# subscription-manager config --rhsm.manage_repos=1
# subscription-manager syspurpose role --set "Red Hat Enterprise Linux Server"
# subscription-manager syspurpose service-level --set "Self-Support"
# subscription-manager syspurpose usage --set "Production"
# subscription-manager repos --enable rhel-9-for-x86_64-supplementary-rpms
# dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

dnf -y install git-core; dnf -y update; reboot
##
mkdir /work; chown ec2-user:ec2-user /work; chmod 755 /work
cd /work; git clone https://github.com/Ice4Dev/rhel9-disastig-partition.git; cd rhel9-disastig-partition
sh ./prereq.sh

## adjust vol sizes below (/home will get a later added 1T volume mounted)
ansible-playbook --extra-vars "vol_new_size=90" --extra-vars "tmp_size=3" --extra-vars "opt_size=40" --extra-vars "audit_size=3" --extra-vars "var_size=5" --extra-vars "log_size=5" ec2-partitions.yml
cd; rm -rf /work

## Remove nosuid, noexec from /opt in /etc/fstab

passwd -l amalocal
/usr/bin/chage -I -1 -m 0 -M 99999 -E -1 amalocal

useradd -g 1000 mwmoorcroft_admin
usermod -a -G 'wheel' mwmoorcroft_admin
passwd -l mwmoorcroft_admin
/usr/bin/chage -I -1 -m 0 -M 99999 -E -1 mwmoorcroft_admin

useradd -g 1000 ijwilliams.admin
usermod -a -G 'wheel' ijwilliams.admin
passwd -l ijwilliams.admin
/usr/bin/chage -I -1 -m 0 -M 99999 -E -1 ijwilliams.admin

useradd -g 1000 jhodonald.admin
usermod -a -G 'wheel' jhodonald.admin
passwd -l jhodonald.admin
/usr/bin/chage -I -1 -m 0 -M 99999 -E -1 jhodonald.admin

groupadd -g 1101 nssam
groupadd -g 1103 MCNP


sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/sysconfig/selinux
grubby --update-kernel ALL --args selinux=0
systemctl disable --now kdump
dnf -y groupinstall "Development Tools"
dnf -y install aide rsyslog-crypto liblockfile pam_ssh_agent_auth
cat << 'EOF' > /etc/rsyslog.d/10-systemd.conf
if $syslogtag startswith 'systemd' then {
    action(type="omfile" file="/var/log/systemd")
    if $syslogseverity > 1 then stop
}
EOF
systemctl enable --now rsyslog

##auditd
#sed -i -e 's/priority_boost = 4/priority_boost = 6/' /etc/audit/auditd.conf
#sed -i -e 's/num_logs = 5/num_logs = 90/' /etc/audit/auditd.conf # SIEM
sed -i -e 's/name_format = NONE/name_format = hostname/' /etc/audit/auditd.conf # SIEM
#sed -i -e 's/max_log_file = 6/max_log_file = 100/' /etc/audit/auditd.conf # SIEM
#sed -i -e 's/max_log_file_action = ROTATE/max_log_file_action = IGNORE/' /etc/audit/auditd.conf
sed -i -e 's/space_left_action = SYSLOG/space_left_action = EMAIL/' /etc/audit/auditd.conf

# OHPC requires 022 umask for root ops
cat << 'EOF' >> /root/.bashrc

# required for ohpc admin ops
umask 022

# Avoid succesive duplicates in the bash command history.
export HISTCONTROL=ignoredups

# Add bash aliases.
if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi

EOF

cat << 'EOF' > /root/.bash_aliases
alias sacct='sacct --format=User,Partition,JobID,AllocCPU,JobName,ExitCode,End | less'
alias du='du -h --max-depth=1'

function scp_tar()
{
echo ""
echo "usage: scp_tar '/source path' 'destination host' '/dest path/'"
echo ""
tar -pcvf - $1 | throttle -v -m 1 -w 60 -l /tmp/root-throttle | ssh -f $2 "cd $3; tar -pxvf -"
}
EOF

## network --onboot=on --device=eth1 --bootproto=static --ip=172.16.1.10 --netmask=255.255.255.240 --noipv6 --nodefroute

dnf -y install postfix dnf-automatic logwatch

# Create admin users in /etc/aliases and run newaliases

cat << 'EOF' > /etc/sudoers.d/sudoers
## Set Default sudo PATH
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# allows PAM to use the SSH agent
Defaults    env_keep += "SSH_AUTH_SOCK"

%nssam ALL = (root) NOPASSWD: /usr/bin/scontrol update nodename=c[1-4] state=idle
EOF

sed -i -e 's/^emit_via = stdio/emit_via = email/' /etc/dnf/automatic.conf
sed -i -e 's/^email_from = root@example.com/email_from = root@thor3-head.ama-inc.com/' /etc/dnf/automatic.conf

# Run logwatch weekly
mv /etc/cron.daily/0logwatch /etc/cron.weekly/
touch /etc/cron.daily/0logwatch

# Reduce saved yum kernel versions to 3 to conserve /boot space
# sed -i -e 's/installonly_limit=5/installonly_limit=3/' /etc/dnf/dnf.conf

# Install Cortex
dnf -y install selinux-policy-devel
mkdir -p /etc/panw
cat << 'EOF' > /etc/panw/cortex.conf
--distribution-id aea233b264b142ffb90fe03556b5fb8f
--distribution-server https://distributions.traps.paloaltonetworks.com/
EOF
restorecon -R /etc/panw
wget https://docs.paloaltonetworks.com/content/dam/techdocs/en_US/zip/cortex-xdr/cortex-xdr-agent.zip
unzip cortex-xdr-agent.zip
rpm --import cortex-xdr-agent.asc
wget --no-check-certificate https://exploration.ama-inc.com/kick/cortex-7.8.1.76251.rpm
#setsebool -P antivirus_can_scan_system 1
#setsebool -P antivirus_use_jit 1
dnf -y localinstall cortex-7.8.1.76251.rpm
rm -f /root/cortex*

# Install Ninja (fips mode "rpm -ivh --nodigest --nofiledigest ninja-xxx.rpm")
wget --no-check-certificate https://exploration.ama-inc.com/kick/internalinfrastructuremainoffice-5.3.5097-installer.rpm
rpm -ivh --nodigest --nofiledigest internalinfrastructuremainoffice-5.3.5097-installer.rpm
rm -f internalinfrastructuremainoffice-5.3.5097-installer.rpm
cat << 'EOF' >> /etc/systemd/system/multi-user.target.wants/ninjarmm-agent.service
StandardOutput=null
EOF

mkdir /root/Scripts

# Set up TCP wrappers
cat << 'EOF' > /etc/hosts.allow
#
# hosts.allow	This file contains access rules which are used to
#		allow or deny connections to network services that
#		either use the tcp_wrappers library or that have been
#		started through a tcp_wrappers-enabled xinetd.
#
#		See 'man 5 hosts_options' and 'man 5 hosts_access'
#		for information on rule syntax.
#		See 'man tcpd' for information on tcp_wrappers
#
ALL: 127.0.0.1
ALL: 10.10.0.18
ALL: 172.16.0.0/255.255.255.240
EOF

cat << 'EOF' >> /etc/hosts.deny
ALL: ALL
EOF

# Setup pam_ssh_agent_auth
cat << EOF > /etc/pam.d/sudo
#%PAM-1.0
auth       sufficient   pam_ssh_agent_auth.so file=%h/.ssh/authorized_keys debug
auth       include      system-auth
account    include      system-auth
password   include      system-auth
session    include      system-auth
EOF

# Postfix no IPv6 fix
sed -i -e 's/^inet_protocols = all/inet_protocols = ipv4/' /etc/postfix/main.cf
sed -i "s/^::1/#&/" /etc/hosts
systemctl enable postfix
systemctl start postfix

# Authenticated SMTP
dnf -y install cyrus-sasl cyrus-sasl-md5
systemctl enable saslauthd
systemctl start saslauthd
cat << 'EOF' > /etc/postfix/sasl_passwd
[amainc-com0i.mail.protection.outlook.com] scanner@ama-inc.com:ManBearPig21211!@#
EOF

cat << 'EOF' >> /etc/postfix/main.cf

relayhost = [amainc-com0i.mail.protection.outlook.com]
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_auth_enable = yes
smtp_generic_maps = hash:/etc/postfix/generic
smtp_tls_security_level = may
smtp_sasl_security_options = noanonymous

EOF

postmap hash:/etc/postfix/sasl_passwd
postmap hash:/etc/postfix/generic
systemctl restart postfix

# Banner text (cat AMA_banner.txt > /etc/issue)
sed -i "s/#Banner none/Banner \/etc\/issue/g" /etc/ssh/sshd_config
sed -i "s/Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-cbc,3des-cbc,aes192-cbc,aes256-cbc/Ciphers aes128-ctr,aes192-ctr,aes256-ctr/g" /etc/ssh/sshd_config
sed -i "s/\<LC_ALL\>//g" /etc/ssh/sshd_config
sed -i "s/\<LANG\>//g" /etc/ssh/sshd_config

cat << 'EOF' > /etc/issue

-- WARNING -- This system is for the use of authorized users only. Individuals
using this computer system without authority or in excess of their authority
are subject to having all their activities on this system monitored and
recorded by system personnel. Anyone using this system expressly consents to
such monitoring and is advised that if such monitoring reveals possible
evidence of criminal activity system personal may provide the evidence of such
monitoring to law enforcement officials.

EOF

grep -q ^weekly /etc/logrotate.conf && \
sed -i "s/weekly/daily/g" /etc/logrotate.conf
sed -i "s/rotate 4/rotate 30/g" /etc/logrotate.conf
sed -i "s/#compress/compress/g" /etc/logrotate.conf

sed -i '/aide/d' /etc/crontab
sed -i -e 's/LOG = p+u+g+n+acl+selinux+ftype+xattrs+sha512/LOG = p+u+g+n+acl+selinux+ftype+xattrs/' /etc/aide.conf
cat << 'EOF' >> /etc/aide.conf

# Cortex, Ninja ignores
!/opt/NinjaRMMAgent
!/opt/traps
!/opt/rapid7
!/var/log
!/var/spool

EOF
# There are rules referring to non-existent directory /etc/avahi
# There are rules referring to non-existent directory /etc/certmonger
# There are rules referring to non-existent directory /etc/cups
# There are rules referring to non-existent directory /etc/cupshelpers
# There are rules referring to non-existent directory /etc/httpd
# There are rules referring to non-existent directory /etc/ipsec.d
# There are rules referring to non-existent directory /etc/named
# There are rules referring to non-existent directory /etc/stunnel
# There are rules referring to non-existent directory /etc/usbguard
# There are rules referring to non-existent directory /etc/wpa_supplicant
# There are rules referring to non-existent directory /var/spool/at

cat << 'EOF' > /root/Scripts/aide.sh
#!/bin/bash

database=/var/lib/aide/aide.db.gz
database_out=/var/lib/aide/aide.db.new.gz
ADDR="root@localhost"
HOST=`hostname -s`
mv $database_out $database
aide --update
aide --check --verbose > /tmp/aide.txt
grep "Looks okay" /tmp/aide.txt &> /dev/null
if [[ $? == "0" ]]; then
    exit
else
    cat /tmp/aide.txt | mail -s "$HOST AIDE Report" $ADDR
fi
rm /tmp/aide.txt
EOF
chmod 700 /root/Scripts/aide.sh

aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# root crontab -e add
# SHELL=/bin/bash
# PATH=/sbin:/bin:/usr/sbin:/usr/bin
# MAILTO=root
# 
# # For details see man 4 crontabs
# 
# # Example of job definition:
# # .---------------- minute (0 - 59)
# # |  .------------- hour (0 - 23)
# # |  |  .---------- day of month (1 - 31)
# # |  |  |  .------- month (1 - 12) OR jan,feb,mar,apr ...
# # |  |  |  |  .---- day of week (0 - 6) (Sunday=0 or 7) OR sun,mon,tue,wed,thu,fri,sat
# # |  |  |  |  |
# # *  *  *  *  * user-name  command to be executed
# 
# 0 2 * * * /root/Scripts/aide.sh > /dev/null 2>&1
# 0 * * * * /root/Scripts/netstat.sh > /dev/null 2>&1

cat << 'EOF' > /etc/audit/rules.d/sudo.rules
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=4294967295 -F key=privileged
-a always,exit -F path=/usr/bin/sudoedit -F perm=x -F auid>=1000 -F auid!=4294967295 -F key=privileged
EOF
cat << 'EOF' > /etc/audit/rules.d/immutable.rules
# Set the audit.rules configuration immutable per security requirements
# Reboot is required to change audit rules once this setting is applied

# Set the audit.rules configuration to immutable per security requirements
-e 2
# Set the audit.rules configuration to halt system upon audit failure per security requirements
# Not practical on a VM
# -f 2
# Set rate of generated messages
-r 200
EOF

cat << 'EOF' > /etc/sysctl.d/AMA-sysctl.conf
net.ipv4.tcp_timestamps = 0
EOF

dnf -y install audispd-plugins
sed -i "s/active = no/active = yes/g" /etc/audit/plugins.d/syslog.conf

# semanage port -a -t syslog_tls_port_t -p tcp 514
# rsyslog forward to ama Logrythm log server
cat << 'EOF' > /etc/rsyslog.d/ratelimit.conf
##
## /etc/rsyslog.d/ratelimit.conf
##
##
## Remove ratelimits to ensure we capture everything sent to us
##

# $SystemLogRateLimitInterval 0
# $SystemLogRateLimitBurst 0


## The following controls rate limits from the local systemd journal
## Adjusting these may not be appropriate, but doing so will ensure
## that this machine logs in the same way as remote clients

$imjournalRatelimitInterval 0
$imjournalRatelimitBurst 0
EOF

cat << 'EOF' > /etc/rsyslog.d/to_remote.conf
##
## /etc/rsyslog.d/to_remote.conf
##
##
## WARNING: ALL TCP METHODS MUST USE DISK QUEUES TO HANDLE
## NETWORK PROBLEMS OR RUN THE SERIOUS LIKELYHOOD OF LOCKING
## THE MACHINE DEAD.
##

####################################################################
####################################################################
##
## omfwd protocol
##
## module( load="omfwd" ) # built-in module

ruleset( name="to_remote_omfwd" )
{
    action( type="omfwd"

        target  = "10.5.2.192"
        port    = "514"

        # and queue to disk if needs be
        queue.filename="omfwd_fwd"
        queue.type="LinkedList"
        queue.saveonshutdown="on"
        queue.maxdiskspace="1g"

        action.resumeretrycount="-1"
        action.reportsuspension="on"
    )
}

ruleset( name="to_remote" )
{
    call to_remote_omfwd
}

##
## One of the following two lines should be chosen
##
call to_remote
EOF

## OpenHPC install

# subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms # fails in AWS
# edit /etc/yum/repos.d/redhat-rhui.repo by hand and enable codeready-builder

dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# add 2TB /dev/sdb xfs volume for /home (parted, mkfs.xfs, blkid, fstab)

mkdir /home/shared
chown root:nssam /home/shared
chmod 775 /home/shared

# ImageMagick and patchelf at user request, perl-Switch for slurm
dnf -y install ImageMagick perl-Switch patchelf awscli

dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf config-manager --set-enabled remi
pip3.11 install pipenv

## edit /etc/hostname, /etc/hosts

dnf -y install http://repos.openhpc.community/OpenHPC/3/EL_9/x86_64/ohpc-release-3-1.el9.x86_64.rpm

## Run OpenHPC_rocky9_war4_slurm_recipe.sh with input.local copied in place

# Edit /etc/ssh/sshd_config uncomment #AllowUsers *@10.2.2.166
# Edit /etc/hosts.allow uncomment 10.2.2.166 line

yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
yum -y install terraform
git clone https://github.com/clusterinthecloud/terraform.git
git clone https://github.com/clusterinthecloud/installer.git
aws configure
cd terraform
