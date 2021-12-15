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


  - path: '/etc/slurm/slurm.conf.d/slurm_nodes.conf'
    permissions: '0644'
    content: |
      NodeName=%NAME%
      NodeName=compute[1-100] State=Cloud

  - path: '/usr/bin/stop_ec2_compute'
    permissions: '0700'
    content: |
      #!/bin/bash
      hosts=$($SLURM_ROOT/bin/scontrol show hostnames $1)
      for host in $hosts
      do
        filt="[{\"Name\": \"tag:Name\", \"Values\": [\"$host\"]},{\"Name\": \"instance-state-name\", \"Values\": [\"running\"]}]"
        aws ec2 describe-instances  --filters "$filt" --region ${data.aws_region.current.name}   --query 'Reservations[*].Instances[*].InstanceId'| grep i- | tr -d '"' | xargs -n 1 aws ec2 terminate-instances --region ${data.aws_region.current.name} --instance-ids
      done  
  - path: '/usr/bin/start_ec2_compute'
    permissions: '0700'
    content: |
      #!/bin/bash
      hosts=$($SLURM_ROOT/bin/scontrol show hostnames $1)
      latest_ver=$(aws ec2 describe-launch-template-versions --launch-template-name slurm_compute --region ${data.aws_region.current.name} --query LaunchTemplateVersions[*].VersionNumber | grep -oE '[[:digit:]]*' | sort -nr | head -1)
      for host in $hosts
      do
        aws ec2 run-instances --launch-template LaunchTemplateName=slurm_compute,Version=$latest_ver --region ${data.aws_region.current.name} --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$host}]"
      done
EOF
}

## Sec group must be adapted to allow intra-VPC communications
resource "aws_security_group" "controller_ssh" {
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [aws_vpc.hpc.cidr_block]
  }
}

