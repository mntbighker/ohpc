#!/bin/bash
#

if [ $USER != "root" ]; then
  echo "You must be root to execute this script."
  exit
fi

# Compute node list
printf "Node List\n"
printf "================\n"
scontrol show node ${i} | grep -A1 NodeAddr

printf "\n\n"

printf "Partition Names\n"
printf "================\n"
scontrol show partition | grep PartitionName
printf "\n"

printf "QoS Properties\n"
printf "================\n"
sacctmgr show qos format=name,priority,MaxJobs,MaxSubmit,MaxNodes
printf "\n"

printf "Partition Properties\n"
printf "=====================\n"
qstat -q

# List Users
printf "Users\n"
printf "================\n"
sacctmgr show associations format=account,user,partition,qos,defaultqos
printf "\n"

sleep 10

accounts=`sacctmgr -n -P show account format=account | grep -v root`
users=`sacctmgr -n -P show user format=user | grep -v root`

for i in $users
do
   sacctmgr -iQ delete user $i
done

for i in $accounts
do
   sacctmgr -iQ delete account $i
done

sacctmgr -iQ add account nssam

# Delete existing QoS'
sacctmgr -iQ delete qos normal
sacctmgr -iQ delete qos production_qos
sacctmgr -iQ delete qos debug_qos
sacctmgr -iQ delete qos batch_qos
sacctmgr -iQ delete qos long_qos

# Create QoS: production
sacctmgr -iQ add qos production_qos
sacctmgr -iQ modify qos production_qos set priority=30
sacctmgr -iQ modify qos production_qos set MaxJobs=4
sacctmgr -iQ modify qos production_qos set MaxSubmitJobs=2
sacctmgr -iQ modify qos production  qos set MaxNodes=4
sacctmgr -iQ modify qos production_qos set flags=DenyOnLimit

# Create QoS: debug
sacctmgr -iQ add qos debug_qos
sacctmgr -iQ modify qos debug_qos set priority=60
sacctmgr -iQ modify qos debug_qos set MaxJobs=1
sacctmgr -iQ modify qos debug_qos set MaxSubmitJobs=2
sacctmgr -iQ modify qos debug_qos set MaxNodes=1
sacctmgr -iQ modify qos debug_qos set flags=DenyOnLimit
 
# Create QoS: batch
sacctmgr -iQ add qos batch_qos
sacctmgr -iQ modify qos batch_qos set priority=15
sacctmgr -iQ modify qos batch_qos set MaxJobs=4
sacctmgr -iQ modify qos batch_qos set MaxSubmitJobs=32
sacctmgr -iQ modify qos batch  qos set MaxNodes=4
sacctmgr -iQ modify qos batch_qos set flags=DenyOnLimit
 
# Create QoS: long
sacctmgr -iQ add qos long_qos
sacctmgr -iQ modify qos long_qos set priority=5
sacctmgr -iQ modify qos long_qos set MaxJobs=1
sacctmgr -iQ modify qos long_qos set MaxSubmitJobs=10
sacctmgr -iQ modify qos long_qos set MaxNodes=4
sacctmgr -iQ modify qos long_qos set flags=DenyOnLimit

NSSAM=`getent passwd | grep -vE '(nologin|false)$' | grep ":1101:" | awk -F: '{print$1}' | sort -u`

for i in "${NSSAM[@]}"
do
   sacctmgr -iQ add user name=${i} defaultaccount=nssam account=nssam part=production qos=production_qos defaultqos=production_qos
   sacctmgr -iQ add user name=${i} defaultaccount=nssam account=nssam part=debug qos=debug_qos defaultqos=debug_qos
   sacctmgr -iQ add user name=${i} defaultaccount=nssam account=nssam part=batch qos=batch_qos defaultqos=batch_qos
   sacctmgr -iQ add user name=${i} defaultaccount=nssam account=nssam part=long qos=long_qos defaultqos=long_qos
done

cat << 'EOF' >> /mnt/shared/etc/slurm/slurm.conf
# NodeName=c[1-4] CoresPerSocket=8 RealMemory=4886 State=UNKNOWN Feature=8CPUs

PartitionName=production QoS=production_qos AllowQoS=production_qos nodes=ALL Default=YES DefaultTime=01:00:00 MaxTime=1-0 State=UP DisableRootJobs=yes MaxMemPerCPU=14000 DefMemPerCPU=12000
PartitionName=debug QoS=debug_qos AllowQoS=debug_qos nodes=ALL Default=NO DefaultTime=01:00:00 MaxTime=1-0 State=UP DisableRootJobs=yes MaxMemPerCPU=14000 DefMemPerCPU=12000
PartitionName=batch QoS=batch_qos AllowQoS=batch_qos nodes=ALL Default=NO DefaultTime=01:00:00 MaxTime=3-0 State=UP DisableRootJobs=yes MaxMemPerCPU=14000 DefMemPerCPU=12000
PartitionName=long QoS=long_qos AllowQoS=long_qos nodes=ALL Default=NO DefaultTime=01:00:00 MaxTime=5-0 State=UP DisableRootJobs=yes MaxMemPerCPU=14000 DefMemPerCPU=12000
EOF
systemctl restart slurmctld
# scontrol update nodename=c[1-4] state=idle

# List Partition Properties
printf "Partition Properties\n"
printf "=====================\n"
scontrol show partition
printf "\n"

# List QoS Properties
printf "QoS Properties\n"
printf "================\n"
sacctmgr show qos format=name,priority,MaxJobs,MaxSubmit,MaxNodes
printf "\n"

# List Users
printf "Users\n"
printf "================\n"
sacctmgr show associations format=account,user,partition,qos,defaultqos
printf "\n"

# List Partitions
printf "Partitions\n"
printf "================\n"
squeue
