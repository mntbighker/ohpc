#!/usr/bin/bash
# -----------------------------------------------------------------------------------------
#  Example Installation Script Template
#  This convenience script encapsulates command-line instructions highlighted in
#  an OpenHPC Install Guide that can be used as a starting point to perform a local
#  cluster install beginning with bare-metal. Necessary inputs that describe local
#  hardware characteristics, desired network settings, and other customizations
#  are controlled via a companion input file that is used to initialize variables
#  within this script.
#  Please see the OpenHPC Install Guide(s) for more information regarding the
#  procedure. Note that the section numbering included in this script refers to
#  corresponding sections from the companion install guide.
# -----------------------------------------------------------------------------------------

# sh ./recipe.sh > OpenHPC.log 2>&1

inputFile=${OHPC_INPUT_LOCAL:-/root/input.local}

if [ ! -e ${inputFile} ];then
   echo "Error: Unable to access local input file -> ${inputFile}"
   exit 1
else
   . ${inputFile} || { echo "Error sourcing ${inputFile}"; exit 1; }
fi

# ---------------------------- Begin OpenHPC Recipe ---------------------------------------
# Commands below are extracted from an OpenHPC install guide recipe and are intended for
# execution on the master SMS host.
# -----------------------------------------------------------------------------------------

# Verify OpenHPC repository has been enabled before proceeding

dnf repolist | grep -q OpenHPC
if [ $? -ne 0 ];then
   echo "Error: OpenHPC repository must be enabled locally"
   exit 1
fi

# Disable firewall
systemctl disable --now firewalld

# ------------------------------------------------------------
# Add baseline OpenHPC and provisioning services (Section 3.3)
# ------------------------------------------------------------
dnf -y install ohpc-base warewulf-ohpc hwloc-ohpc
# Enable NTP services on SMS host
systemctl enable chronyd.service
echo "local stratum 10" >> /etc/chrony.conf
echo "server ${ntp_server}" >> /etc/chrony.conf
echo "allow all" >> /etc/chrony.conf
systemctl restart chronyd

# -------------------------------------------------------------
# Add resource management services on master node (Section 3.4)
# -------------------------------------------------------------
dnf -y install ohpc-slurm-server
cp /etc/slurm/slurm.conf.ohpc /etc/slurm/slurm.conf
cp /etc/slurm/cgroup.conf.example /etc/slurm/cgroup.conf
perl -pi -e "s/SlurmctldHost=\S+/SlurmctldHost=${sms_name}/" /etc/slurm/slurm.conf

# ----------------------------------------
# Update node configuration for slurm.conf
# ----------------------------------------
if [[ ${update_slurm_nodeconfig} -eq 1 ]];then
     perl -pi -e "s/^NodeName=.+$/#/" /etc/slurm/slurm.conf
     perl -pi -e "s/ Nodes=c\S+ / Nodes=${compute_prefix}[1-${num_computes}] /" /etc/slurm/slurm.conf
     echo -e ${slurm_node_config} >> /etc/slurm/slurm.conf
fi

# -----------------------------------------------------------------------
# Optionally add InfiniBand support services on master node (Section 3.5)
# -----------------------------------------------------------------------
if [[ ${enable_ib} -eq 1 ]];then
     dnf -y groupinstall "InfiniBand Support"
     udevadm trigger --type=devices --action=add
     systemctl restart rdma-load-modules@infiniband.service
fi

# Optionally enable opensm subnet manager
if [[ ${enable_opensm} -eq 1 ]];then
     dnf -y install opensm
     systemctl enable opensm
     systemctl start opensm
fi

# Optionally enable IPoIB interface on SMS
if [[ ${enable_ipoib} -eq 1 ]];then
     # Enable ib0
     cp /opt/ohpc/pub/examples/network/centos/ifcfg-ib0 /etc/sysconfig/network-scripts
     perl -pi -e "s/master_ipoib/${sms_ipoib}/" /etc/sysconfig/network-scripts/ifcfg-ib0
     perl -pi -e "s/ipoib_netmask/${ipoib_netmask}/" /etc/sysconfig/network-scripts/ifcfg-ib0
     echo "[main]"   >  /etc/NetworkManager/conf.d/90-dns-none.conf
     echo "dns=none" >> /etc/NetworkManager/conf.d/90-dns-none.conf
     systemctl start NetworkManager
fi

# ----------------------------------------------------------------------
# Optionally add Omni-Path support services on master node (Section 3.6)
# ----------------------------------------------------------------------
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y install opa-basic-tools
fi

# Optionally enable OPA fabric manager
if [[ ${enable_opafm} -eq 1 ]];then
     dnf -y install opa-fm
     systemctl enable opafm
     systemctl start opafm
fi

# -----------------------------------------------------------
# Complete basic Warewulf setup for master node (Section 3.7)
# -----------------------------------------------------------
ip link set dev ${sms_eth_internal} up
ip address add ${sms_ip}/${internal_netmask} broadcast + dev ${sms_eth_internal}
perl -pi -e "s/ipaddr:.*/ipaddr: ${sms_ip}/" /etc/warewulf/warewulf.conf
perl -pi -e "s/netmask:.*/netmask: ${internal_netmask}/" /etc/warewulf/warewulf.conf
perl -pi -e "s/network:.*/network: ${internal_network}/" /etc/warewulf/warewulf.conf
perl -pi -e 's/template:.*/template: static/' /etc/warewulf/warewulf.conf
perl -pi -e "s/range start:.*/range start: ${c_ip[0]}/" /etc/warewulf/warewulf.conf
perl -pi -e "s/range end:.*/range end: ${c_ip[$((num_computes-1))]}/" /etc/warewulf/warewulf.conf
perl -pi -e "s/mount: false/mount: true/" /etc/warewulf/warewulf.conf
wwctl profile set -y default --netmask=${internal_netmask}
wwctl profile set -y default --gateway=${ipv4_gateway}
wwctl profile set -y default --netdev=default --nettagadd=DNS=${dns_servers}
perl -pi -e "s/warewulf/${sms_name}/" /srv/warewulf/overlays/host/rootfs/etc/hosts.ww
perl -pi -e "s/warewulf/${sms_name}/" /srv/warewulf/overlays/generic/rootfs/etc/hosts.ww
echo "next-server ${sms_ip};" >> /srv/warewulf/overlays/host/rootfs/etc/dhcpd.conf.ww
systemctl enable --now warewulfd
wwctl configure --all
bash /etc/profile.d/ssh_setup.sh

# Update /etc/hosts template to have ${hostname}.localdomain as the first host entry
sed -e 's_\({{$node.Id.Get}}{{end}}\)_{{$node.Id.Get}}.localdomain \1_g' -i /srv/warewulf/overlays/host/rootfs/etc/hosts.ww

# -------------------------------------------------
# Create compute image for Warewulf (Section 3.8.1)
# -------------------------------------------------
wwctl container import docker://ghcr.io/warewulf/warewulf-rockylinux:9.5 rhel-9.5 --syncuser
wwctl container exec rhel-9.5 /bin/bash <<- EOF
dnf -y install http://repos.openhpc.community/OpenHPC/3/EL_9/x86_64/ohpc-release-3-1.el9.x86_64.rpm
dnf -y update
EOF
export CHROOT=/srv/warewulf/chroots/rhel-9.5/rootfs

# ------------------------------------------------------------
# Add OpenHPC base components to compute image (Section 3.8.2)
# ------------------------------------------------------------
wwctl container exec rhel-9.5 /bin/bash <<- EOF
dnf -y install ohpc-base-compute
EOF
# Add SLURM and other components to compute instance
wwctl container exec rhel-9.5 /bin/bash <<- EOF
# Add Slurm client support meta-package and enable munge and slurmd
dnf -y install ohpc-slurm-client
systemctl enable munge
systemctl enable slurmd

# Add Network Time Protocol (NTP) support
dnf -y install chrony

# Include modules user environment
dnf -y install lmod-ohpc
EOF
if [[ ${enable_intel_packages} -eq 1 ]];then
     mkdir /opt/intel
     echo "/opt/intel *(ro,no_subtree_check,fsid=12)" >> /etc/exports
     echo "${sms_ip}:/opt/intel /opt/intel nfs nfsvers=4,nodev 0 0" >> $CHROOT/etc/fstab
fi

# Update basic slurm configuration if additional computes defined
if [ ${num_computes} -gt 4 ];then
   perl -pi -e "s/^NodeName=(\S+)/NodeName=${compute_prefix}[1-${num_computes}]/" /etc/slurm/slurm.conf
   perl -pi -e "s/^PartitionName=normal Nodes=(\S+)/PartitionName=normal Nodes=${compute_prefix}[1-${num_computes}]/" /etc/slurm/slurm.conf
fi

# -----------------------------------------
# Additional customizations (Section 3.8.4)
# -----------------------------------------

# Add IB drivers to compute image
if [[ ${enable_ib} -eq 1 ]];then
     dnf -y --installroot=$CHROOT groupinstall "InfiniBand Support"
fi
# Add Omni-Path drivers to compute image
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y --installroot=$CHROOT install opa-basic-tools
     dnf -y --installroot=$CHROOT install libpsm2
fi

# Update memlock settings
perl -pi -e 's/# End of file/\* soft memlock unlimited\n$&/s' /etc/security/limits.conf
perl -pi -e 's/# End of file/\* hard memlock unlimited\n$&/s' /etc/security/limits.conf
perl -pi -e 's/# End of file/\* soft memlock unlimited\n$&/s' $CHROOT/etc/security/limits.conf
perl -pi -e 's/# End of file/\* hard memlock unlimited\n$&/s' $CHROOT/etc/security/limits.conf

# Enable slurm pam module
echo "account    required     pam_slurm.so" >> $CHROOT/etc/pam.d/sshd

if [[ ${enable_beegfs_client} -eq 1 ]];then
     wget -P /etc/yum.repos.d https://www.beegfs.io/release/beegfs_7.4.5/dists/beegfs-rhel9.repo
     dnf -y install kernel-devel gcc elfutils-libelf-devel
     dnf -y install beegfs-client beegfs-helperd beegfs-utils
     perl -pi -e "s/^buildArgs=-j8/buildArgs=-j8 BEEGFS_OPENTK_IBVERBS=1/"  /etc/beegfs/beegfs-client-autobuild.conf
     /opt/beegfs/sbin/beegfs-setup-client -m ${sysmgmtd_host}
     systemctl start beegfs-helperd
     systemctl start beegfs-client
     wget -P $CHROOT/etc/yum.repos.d https://www.beegfs.io/release/beegfs_7.4.5/dists/beegfs-rhel9.repo
     dnf -y --installroot=$CHROOT install beegfs-client beegfs-helperd beegfs-utils
     perl -pi -e "s/^buildEnabled=true/buildEnabled=false/" $CHROOT/etc/beegfs/beegfs-client-autobuild.conf
     rm -f $CHROOT/var/lib/beegfs/client/force-auto-build
     chroot $CHROOT systemctl enable beegfs-helperd beegfs-client
     cp /etc/beegfs/beegfs-client.conf $CHROOT/etc/beegfs/beegfs-client.conf
     echo "drivers += beegfs" >> /etc/warewulf/bootstrap.conf
fi

# Enable Optional packages

if [[ ${enable_lustre_client} -eq 1 ]];then
     # Install Lustre client on master
     dnf -y install lustre-client-ohpc
     # Enable lustre in WW compute image
     dnf -y --installroot=$CHROOT install lustre-client-ohpc
     mkdir $CHROOT/mnt/lustre
     echo "${mgs_fs_name} /mnt/lustre lustre defaults,localflock,noauto,x-systemd.automount 0 0" >> $CHROOT/etc/fstab
     # Enable o2ib for Lustre
     echo "options lnet networks=o2ib(ib0)" >> /etc/modprobe.d/lustre.conf
     echo "options lnet networks=o2ib(ib0)" >> $CHROOT/etc/modprobe.d/lustre.conf
     # mount Lustre client on master
     mkdir /mnt/lustre
     mount -t lustre -o localflock ${mgs_fs_name} /mnt/lustre
fi


# -------------------------------------------------------
# Configure rsyslog on SMS and computes (Section 3.8.4.7)
# -------------------------------------------------------
echo 'module(load="imudp")' >> /etc/rsyslog.d/ohpc.conf
echo 'input(type="imudp" port="514")' >> /etc/rsyslog.d/ohpc.conf
systemctl restart rsyslog
echo "*.* action(type=\"omfwd\" Target=\"${sms_ip}\" Port=\"514\" " "Protocol=\"udp\")">> $CHROOT/etc/rsyslog.conf
perl -pi -e "s/^\*\.info/\\#\*\.info/" $CHROOT/etc/rsyslog.conf
perl -pi -e "s/^authpriv/\\#authpriv/" $CHROOT/etc/rsyslog.conf
perl -pi -e "s/^mail/\\#mail/" $CHROOT/etc/rsyslog.conf
perl -pi -e "s/^cron/\\#cron/" $CHROOT/etc/rsyslog.conf
perl -pi -e "s/^uucp/\\#uucp/" $CHROOT/etc/rsyslog.conf

if [[ ${enable_clustershell} -eq 1 ]];then
     # Install clustershell
     dnf -y install clustershell
     cd /etc/clustershell/groups.d
     mv local.cfg local.cfg.orig
     echo "adm: ${sms_name}" > local.cfg
     echo "compute: ${compute_prefix}[1-${num_computes}]" >> local.cfg
     echo "all: @adm,@compute" >> local.cfg
fi

if [[ ${enable_genders} -eq 1 ]];then
     # Install genders
     dnf -y install genders-ohpc
     echo -e "${sms_name}\tsms" > /etc/genders
     for ((i=0; i<$num_computes; i++)) ; do
        echo -e "${c_name[$i]}\tcompute,bmc=${c_bmc[$i]}"
     done >> /etc/genders
fi

if [[ ${enable_magpie} -eq 1 ]];then
     # Install magpie
     dnf -y install magpie-ohpc
fi

# Optionally, enable conman and configure
if [[ ${enable_ipmisol} -eq 1 ]];then
     dnf -y install conman-ohpc
     for ((i=0; i<$num_computes; i++)) ; do
        echo -n 'CONSOLE name="'${c_name[$i]}'" dev="ipmi:'${c_bmc[$i]}'" '
        echo 'ipmiopts="'U:${bmc_username},P:${IPMI_PASSWORD:-undefined},W:solpayloadsize'"'
     done >> /etc/conman.conf
     systemctl enable conman
     systemctl start conman
fi

# Optionally, enable nhc and configure
dnf -y install nhc-ohpc
dnf -y --installroot=$CHROOT install nhc-ohpc

echo "HealthCheckProgram=/usr/sbin/nhc" >> /etc/slurm/slurm.conf
echo "HealthCheckInterval=300" >> /etc/slurm/slurm.conf  # execute every five minutes

# Optionally, update compute image to support geopm
if [[ ${enable_geopm} -eq 1 ]];then
     export kargs="${kargs} intel_pstate=disable"
fi

if [[ ${enable_geopm} -eq 1 ]];then
     dnf -y --installroot=$CHROOT install kmod-msr-safe-ohpc
     dnf -y --installroot=$CHROOT install msr-safe-ohpc
     dnf -y --installroot=$CHROOT install msr-safe-slurm-ohpc
fi

# ----------------------------
# Import files (Section 3.8.5)
# ----------------------------
wwctl overlay import generic /etc/subuid
wwctl overlay import generic /etc/subgid
echo "server ${sms_ip} iburst" | wwctl overlay import generic <(cat) /etc/chrony.conf
wwctl overlay mkdir generic /etc/sysconfig/
wwctl overlay import generic <(echo SLURMD_OPTIONS="--conf-server ${sms_ip}") /etc/sysconfig/slurmd
wwctl overlay mkdir generic --mode 0700 /etc/munge
wwctl overlay import generic /etc/munge/munge.key
wwctl overlay chown generic /etc/munge/munge.key $(id -u munge) $(id -g munge)
wwctl overlay chown generic /etc/munge $(id -u munge) $(id -g munge)

if [[ ${enable_ipoib} -eq 1 ]];then
     wwctl overlay mkdir generic /etc/sysconfig/network-scripts/
     wwctl overlay import generic /opt/ohpc/pub/examples/network/centos/ifcfg-ib0.ww /etc/sysconfig/network-scripts/ifcfg-ib0.ww
fi

# --------------------------------------
# Assemble bootstrap image (Section 3.9)
# --------------------------------------
wwctl container build rhel-9.5
wwctl overlay build
# Add hosts to cluster
for ((i=0; i<$num_computes; i++)) ; do
   wwctl node add --container=rhel-9.5 \
   --ipaddr=${c_ip[$i]} --hwaddr=${c_mac[$i]} ${c_name[i]}
done
wwctl overlay build
wwctl configure --all
# Enable and start munge and slurmctld (Cont.)
systemctl enable --now munge
systemctl enable --now slurmctld

# Optionally, add arguments to bootstrap kernel
if [[ ${enable_kargs} -eq 1 ]]; then
wwctl node set --yes --kernelargs="${kargs}" "${compute_regex}"
fi

# ---------------------------------
# Boot compute nodes (Section 3.10)
# ---------------------------------
for ((i=0; i<${num_computes}; i++)) ; do
   ipmitool -E -I lanplus -H ${c_bmc[$i]} -U ${bmc_username} -P ${bmc_password} chassis power reset
done

# ---------------------------------------
# Install Development Tools (Section 4.1)
# ---------------------------------------
dnf -y install ohpc-autotools
dnf -y install EasyBuild-ohpc
dnf -y install hwloc-ohpc
dnf -y install spack-ohpc
dnf -y install valgrind-ohpc

# -------------------------------
# Install Compilers (Section 4.2)
# -------------------------------
dnf -y install gnu14-compilers-ohpc

# --------------------------------
# Install MPI Stacks (Section 4.3)
# --------------------------------
if [[ ${enable_mpi_defaults} -eq 1 ]];then
     dnf -y install openmpi5-pmix-gnu14-ohpc mpich-ofi-gnu14-ohpc
fi

if [[ ${enable_ib} -eq 1 ]];then
     dnf -y install mvapich2-gnu14-ohpc
fi
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y install mvapich2-psm2-gnu14-ohpc
fi

# ---------------------------------------
# Install Performance Tools (Section 4.4)
# ---------------------------------------
dnf -y install ohpc-gnu14-perf-tools

if [[ ${enable_geopm} -eq 1 ]];then
     dnf -y install ohpc-gnu14-geopm
fi
dnf -y install lmod-defaults-gnu14-openmpi5-ohpc

# ---------------------------------------------------
# Install 3rd Party Libraries and Tools (Section 4.6)
# ---------------------------------------------------
dnf -y install ohpc-gnu14-serial-libs
dnf -y install ohpc-gnu14-io-libs
dnf -y install ohpc-gnu14-python-libs
dnf -y install ohpc-gnu14-runtimes
if [[ ${enable_mpi_defaults} -eq 1 ]];then
     dnf -y install ohpc-gnu14-mpich-parallel-libs
     dnf -y install ohpc-gnu14-openmpi5-parallel-libs
fi
if [[ ${enable_ib} -eq 1 ]];then
     dnf -y install ohpc-gnu14-mvapich2-parallel-libs
fi
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y install ohpc-gnu14-mvapich2-parallel-libs
fi

# ----------------------------------------
# Install Intel oneAPI tools (Section 4.7)
# ----------------------------------------
if [[ ${enable_intel_packages} -eq 1 ]];then
     dnf -y install intel-oneapi-toolkit-release-ohpc
     rpm --import https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
     dnf -y install intel-compilers-devel-ohpc
     dnf -y install intel-mpi-devel-ohpc
     if [[ ${enable_opa} -eq 1 ]];then
          dnf -y install mvapich2-psm2-intel-ohpc
     fi
     dnf -y install openmpi5-pmix-intel-ohpc
     dnf -y install ohpc-intel-serial-libs
     dnf -y install ohpc-intel-geopm
     dnf -y install ohpc-intel-io-libs
     dnf -y install ohpc-intel-perf-tools
     dnf -y install ohpc-intel-python3-libs
     dnf -y install ohpc-intel-mpich-parallel-libs
     dnf -y install ohpc-intel-mvapich2-parallel-libs
     dnf -y install ohpc-intel-openmpi5-parallel-libs
     dnf -y install ohpc-intel-impi-parallel-libs
fi

# -------------------------------------------------------------
# Allow for optional sleep to wait for provisioning to complete
# -------------------------------------------------------------
sleep ${provision_wait}

# ------------------------------------
# Resource Manager Startup (Section 5)
# ------------------------------------
systemctl enable munge
systemctl enable slurmctld
systemctl start munge
systemctl start slurmctld
pdsh -w ${compute_prefix}[1-${num_computes}] systemctl start munge
pdsh -w ${compute_prefix}[1-${num_computes}] systemctl start slurmd

# Optionally, generate nhc config
pdsh -w c1 "/usr/sbin/nhc-genconf -H '*' -c -" | dshbak -c
useradd -m test
wwctl overlay build
sleep 90
