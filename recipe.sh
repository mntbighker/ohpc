#!/usr/bin/bash

# sh ./recipe.sh > OpenHPC.log 2>&1

inputFile=${OHPC_INPUT_LOCAL:-/root/input.local}

if [ ! -e ${inputFile} ];then
   echo "Error: Unable to access local input file -> ${inputFile}"
   exit 1
else
   . ${inputFile} || { echo "Error sourcing ${inputFile}"; exit 1; }
fi

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
dnf -y install ohpc-base hwloc-ohpc
# Enable NTP services on SMS host
systemctl enable chronyd.service
echo "local stratum 10" >> /etc/chrony.conf
echo "server ${ntp_server}" >> /etc/chrony.conf
echo "allow all" >> /etc/chrony.conf
systemctl restart chronyd

# -------------------------------------------------------------
# Add resource management services on master node (Section 3.4)
# -------------------------------------------------------------
# dnf -y install ohpc-slurm-server
# cp /etc/slurm/slurm.conf.ohpc /etc/slurm/slurm.conf
# cp /etc/slurm/cgroup.conf.example /etc/slurm/cgroup.conf
# perl -pi -e "s/SlurmctldHost=\S+/SlurmctldHost=${sms_name}/" /etc/slurm/slurm.conf

# ----------------------------------------
# Update node configuration for slurm.conf
# ----------------------------------------
# if [[ ${update_slurm_nodeconfig} -eq 1 ]];then
#      perl -pi -e "s/^NodeName=.+$/#/" /etc/slurm/slurm.conf
#      perl -pi -e "s/ Nodes=c\S+ / Nodes=${compute_prefix}[1-${num_computes}] /" /etc/slurm/slurm.conf
#      echo -e ${slurm_node_config} >> /etc/slurm/slurm.conf
# fi

# -----------------------------------------
# Additional customizations (Section 3.8.4)
# -----------------------------------------

# Update memlock settings
perl -pi -e 's/# End of file/\* soft memlock unlimited\n$&/s' /etc/security/limits.conf
perl -pi -e 's/# End of file/\* hard memlock unlimited\n$&/s' /etc/security/limits.conf
perl -pi -e 's/# End of file/\* soft memlock unlimited\n$&/s' $CHROOT/etc/security/limits.conf
perl -pi -e 's/# End of file/\* hard memlock unlimited\n$&/s' $CHROOT/etc/security/limits.conf

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

# ---------------------------------------
# Install Development Tools (Section 4.1)
# ---------------------------------------
dnf -y install ohpc-autotools
dnf -y install EasyBuild-ohpc
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
