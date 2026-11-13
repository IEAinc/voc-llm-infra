#!/usr/bin/env bash
# 관리자 PC(AWS CLI v2, jq, 관리자 권한 자격증명)에서 실행. 재실행해도 기존 리소스를 재사용한다.
# 모든 리소스에 Project=voc-llm 태그를 붙인다 (aws-voc-user.sh 의 전용 사용자 권한 범위).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; set +a
export AWS_DEFAULT_REGION=$REGION AWS_PROFILE MSYS_NO_PATHCONV=1  # Git Bash 경로 변환 방지
TAG='Key=Project,Value=voc-llm'

# SNS (서울)
TOPIC=$(aws sns create-topic --name voc-llm-alerts --tags "$TAG" --query TopicArn --output text)

# IAM 역할: CloudWatch Agent + SNS 발행
if ! aws iam get-role --role-name voc-llm-ec2 >/dev/null 2>&1; then
  aws iam create-role --role-name voc-llm-ec2 --tags "$TAG" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name voc-llm-ec2 --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
  aws iam create-instance-profile --instance-profile-name voc-llm-ec2 >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name voc-llm-ec2 --role-name voc-llm-ec2
  sleep 15   # IAM 전파 대기
fi
aws iam put-role-policy --role-name voc-llm-ec2 --policy-name sns-publish --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$TOPIC\"}]}"

# 키 페어 (없으면 생성, 개인키는 git 제외 파일로 저장)
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  ( umask 077; aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
      --tag-specifications "ResourceType=key-pair,Tags=[{$TAG}]" \
      --query KeyMaterial --output text | tr -d "\015" > "$KEY_NAME.pem"; echo >> "$KEY_NAME.pem" )  # OpenSSH 는 마지막 줄바꿈 필요
  echo "개인키 저장: infra/$KEY_NAME.pem"
fi

# Security Group (기본 VPC)
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=voc-llm Name=vpc-id,Values="$VPC" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = None ]; then
  SG=$(aws ec2 create-security-group --group-name voc-llm --description "voc-llm relay" --vpc-id "$VPC" \
    --tag-specifications "ResourceType=security-group,Tags=[{$TAG}]" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$ADMIN_CIDR,Description=admin}]" \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=certbot}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$ADMIN_CIDR,Description=admin-ssh}]" >/dev/null
  # Route 53 health checker: Task 9 에서 health check 리전을 이 3곳으로 제한한다
  for cidr in $(curl -s https://ip-ranges.amazonaws.com/ip-ranges.json | jq -r \
      '.prefixes[] | select(.service=="ROUTE53_HEALTHCHECKS" and (.region=="us-east-1" or .region=="ap-northeast-1" or .region=="ap-southeast-1")) | .ip_prefix' | tr -d '\r'); do
    aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$cidr,Description=route53-hc}]" >/dev/null
  done
fi
# 고객사 IP (나중에 aws.env 에 넣고 재실행하면 추가된다. 이미 있으면 무시)
if [ -n "${CUSTOMER_CIDR:-}" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$CUSTOMER_CIDR,Description=customer}]" >/dev/null 2>&1 || true
fi

# EC2
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=voc-llm-relay Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$IID" = None ]; then
  AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)
  IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.small --key-name "$KEY_NAME" \
    --security-group-ids "$SG" --iam-instance-profile Name=voc-llm-ec2 \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=voc-llm-relay},{$TAG}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=voc-llm-relay},{$TAG}]" \
    --query 'Instances[0].InstanceId' --output text)
  aws ec2 wait instance-running --instance-ids "$IID"
fi

# Elastic IP
ALLOC=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=voc-llm --query 'Addresses[0].AllocationId' --output text)
if [ "$ALLOC" = None ]; then
  ALLOC=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=voc-llm},{$TAG}]" --query AllocationId --output text)
fi
aws ec2 associate-address --instance-id "$IID" --allocation-id "$ALLOC" >/dev/null
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)

printf 'INSTANCE_ID=%s\nEIP=%s\nSG_ID=%s\nTOPIC_ARN=%s\n' "$IID" "$EIP" "$SG" "$TOPIC" | tee aws.out
echo "다음: DNS A 레코드 ${DOMAIN:-<도메인>} → $EIP"
