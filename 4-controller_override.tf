resource "aws_instance" "controller" {
  iam_instance_profile = aws_iam_instance_profile.controller.name
  user_data            = <<-EOF
#cloud-config
yum_repos:
  ensiie:
    baseurl: https://tps.delhomme.org/repo/
    gpgcheck: false
    enabled: true
    name: "Slurm repo"

packages:
  - slurm-slurmctld
  - slurm-slurmd
  - slurm-slurmdbd
  - munge
  - python-pip
  - unzip

bootcmd:
  - mkdir -p /etc/slurm/slurm.conf.d/
  - yum install -y epel-release

runcmd:
  - mkdir -p /var/spool/slurm
  - 'chown -R munge:munge /etc/munge'
  - chmod 0600 /etc/munge/munge.key
  - systemctl start munge
  - curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"                                                                                                         
  - unzip awscliv2.zip                                                                                                                                                                        
  - ./aws/install

write_files:
  - path: '/etc/munge/munge.key'
    content: "${random_password.munge_key.result}"

  - path: '/etc/slurm/slurm.conf'
    permissions: '0644'
    content: |
      #
      ClusterName=amazon
      ControlMachine=%NAME%
      ControlAddr=%IP%

      SlurmdUser=root
      SlurmctldPort=6817
      SlurmdPort=6818
      AuthType=auth/munge

      StateSaveLocation=/var/spool/slurm/ctld
      SlurmdSpoolDir=/var/spool/slurm/d
      SwitchType=switch/none
      MpiDefault=none
      SlurmctldPidFile=/var/run/slurmctld.pid
      SlurmdPidFile=/var/run/slurmd.pid
      ProctrackType=proctrack/pgid

      ReturnToService=2

      # TIMERS
      SlurmctldTimeout=300
      SlurmdTimeout=60
      InactiveLimit=0
      MinJobAge=300
      KillWait=30
      Waittime=0
      #
      # SCHEDULING
      SchedulerType=sched/backfill
      SelectType=select/cons_res
      SelectTypeParameters=CR_Core
      FastSchedule=1
      # LOGGING
      SlurmctldDebug=3
      SlurmctldLogFile=/var/log/slurmctld.log
      SlurmdDebug=3
      SlurmdLogFile=/var/log/slurmd.log
      DebugFlags=NO_CONF_HASH
      JobCompType=jobcomp/none

      SuspendTime=60
      ResumeTimeout=500
      TreeWidth=60000
      SuspendExcNodes=%NAME%
      ResumeRate=0
      SuspendRate=0

      SuspendProgram=/usr/bin/stop_ec2_compute
      ResumeProgram=/usr/bin/start_ec2_compute

      include slurm.conf.d/slurm_nodes.conf

      PartitionName=all Nodes=ALL Default=YES MaxTime=INFINITE State=UP
      AccountingStorageType=accounting_storage/slurmdbd


  - path: '/etc/slurm/slurm.conf.d/slurm_nodes.conf'
    permissions: '0644'
    content: |
      NodeName=%NAME%
      NodeName=compute-a-[1-100] Features=${aws_subnet.comp_a.id} State=Cloud
      NodeName=compute-b-[1-100] Features=${aws_subnet.comp_b.id} State=Cloud
      NodeName=compute-c-[1-100] Features=${aws_subnet.comp_c.id} State=Cloud
  - path: '/etc/slurm/slurmdbd.conf'
    permissions: '0644'
    content: |
      AuthType=auth/munge
      AuthInfo=/var/run/munge/munge.socket.2
      DbdAddr=localhost
      DbdHost=localhost
      DbdPort=6819
      DebugLevel=3
      LogFile=/var/log/slurmdbd.log
      PidFile=/var/run/slurmdbd.pid
      StorageType=accounting_storage/mysql
      StorageHost=${aws_db_instance.ct_acct.address}
      StoragePort=${aws_db_instance.ct_acct.port}
      StoragePass=${aws_db_instance.ct_acct.password}
      StorageUser=${aws_db_instance.ct_acct.username}
      StorageLoc=${aws_db_instance.ct_acct.name}

  - path: '/usr/bin/stop_ec2_compute'
    permissions: '0700'
    content: |
      #!/bin/bash
      hosts=$($SLURM_ROOT/bin/scontrol show hostnames $1)
      for host in $hosts
      do
        filt="[{\"Name\": \"tag:Name\", \"Values\": [\"$host\"]},{\"Name\": \"instance-state-name\", \"Values\": [\"running\"]}]"
        aws ec2 describe-instances \
          --filters "$filt" \
          --region ${data.aws_region.current.name} \
          --query 'Reservations[*].Instances[*].InstanceId'| grep i- | tr -d '"' | xargs -n 1 aws ec2 terminate-instances \
            --region ${data.aws_region.current.name} \
            --instance-ids
      done
  - path: '/usr/bin/start_ec2_compute'
    permissions: '0700'
    content: |
      #!/bin/bash
      hosts=$($SLURM_ROOT/bin/scontrol show hostnames $1)
      template="slurm_compute_$(/usr/bin/random_compute)"
      latest_ver=$(aws ec2 describe-launch-template-versions \
        --launch-template-name $template \
        --region ${data.aws_region.current.name} \
        --query LaunchTemplateVersions[*].VersionNumber | grep -oE '[[:digit:]]*' | sort -nr | head -1)
      for host in $hosts
      do
        aws ec2 run-instances \
          --launch-template LaunchTemplateName=$template,Version=$latest_ver \
          --region ${data.aws_region.current.name} \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$host}]"
      done


  - path: '/usr/bin/random_compute'
    permissions: '0700'
    content: |
      #!/bin/bash
      array[0]="a"
      array[1]="b"
      array[2]="c"

      size=$${#array[@]}
      index=$$(($RANDOM % $size))
      echo $${array[$index]}

EOF

  provisioner "remote-exec" {
    inline = [
      "while ! sudo grep 'Cloud-init .* finished' /var/log/cloud-init.log; do echo Waiting for cloud-init to finish && sleep 2; done",
      "sudo sed -i -e 's/%NAME%/${self.private_dns}/' -e 's/%IP%/${self.private_ip}/' /etc/slurm/slurm.conf /etc/slurm/slurm.conf.d/*",
      "echo 'Starting the slurm daemons' && sudo systemctl start slurmctld slurmd slurmdbd",
      "echo 'Adding ${aws_db_instance.ct_acct.name} cluster' && sleep 10 && sudo sacctmgr -i add cluster name=${aws_db_instance.ct_acct.name}",
      "echo 'Sleeping 10 seconds and restarting slurmctld' && sleep 10 && sudo systemctl restart slurmctld",
      "echo 'Sleeping 10 seconds and restarting slurmdbd' && sleep 10 && sudo systemctl restart slurmdbd",
    ]

    connection {
      type        = "ssh"
      user        = "centos"
      private_key = file("my-key-pair")
      host        = self.public_dns
    }
  }
}
