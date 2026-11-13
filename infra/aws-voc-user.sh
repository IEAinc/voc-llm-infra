#!/usr/bin/env bash
# VOC 전용 운영 IAM 사용자(voc-llm-admin)를 만들고 로컬 AWS CLI 프로필 voc-llm 으로 등록한다.
# 관리자 프로필(aws.env 의 AWS_PROFILE)로 실행. 재실행하면 정책만 갱신한다 (액세스 키는 처음 1회만 발급).
# 권한 범위: Project=voc-llm 태그가 붙은 EC2/보안그룹, voc-llm* 이름의 SNS/알람/대시보드/EventBridge 규칙,
# Route 53 health check(리소스 단위 제한 불가), 그리고 조회 권한.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; set +a
export AWS_DEFAULT_REGION=$REGION AWS_PROFILE MSYS_NO_PATHCONV=1  # Git Bash 경로 변환 방지
USER=voc-llm-admin
ACCT=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::$ACCT:policy/voc-llm-admin"

DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "Read", "Effect": "Allow", "Resource": "*", "Action": [
      "ec2:Describe*", "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
      "route53:GetHealthCheck*", "route53:ListHealthChecks", "route53:ListTagsForResource*",
      "events:Describe*", "events:List*", "sns:ListTopics", "sns:ListSubscriptions",
      "ssm:GetParameter", "logs:Describe*", "sts:GetCallerIdentity"]},
    {"Sid": "Instance", "Effect": "Allow", "Resource": "arn:aws:ec2:$REGION:$ACCT:instance/*",
     "Condition": {"StringEquals": {"aws:ResourceTag/Project": "voc-llm"}},
     "Action": ["ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances",
      "ec2:ModifyInstanceAttribute", "ec2:GetConsoleOutput", "ec2:GetConsoleScreenshot",
      "ec2:MonitorInstances", "ec2:UnmonitorInstances"]},
    {"Sid": "SecurityGroup", "Effect": "Allow", "Resource": "arn:aws:ec2:$REGION:$ACCT:security-group/*",
     "Condition": {"StringEquals": {"aws:ResourceTag/Project": "voc-llm"}},
     "Action": ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
      "ec2:ModifySecurityGroupRules", "ec2:UpdateSecurityGroupRuleDescriptionsIngress"]},
    {"Sid": "Sns", "Effect": "Allow", "Action": "sns:*",
     "Resource": ["arn:aws:sns:$REGION:$ACCT:voc-llm-*", "arn:aws:sns:us-east-1:$ACCT:voc-llm-*"]},
    {"Sid": "Alarms", "Effect": "Allow", "Resource": "arn:aws:cloudwatch:*:$ACCT:alarm:voc-llm*",
     "Action": ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:SetAlarmState",
      "cloudwatch:EnableAlarmActions", "cloudwatch:DisableAlarmActions", "cloudwatch:TagResource"]},
    {"Sid": "Dashboard", "Effect": "Allow", "Resource": "arn:aws:cloudwatch::$ACCT:dashboard/voc-llm*",
     "Action": ["cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"]},
    {"Sid": "Events", "Effect": "Allow", "Resource": "arn:aws:events:$REGION:$ACCT:rule/voc-llm*",
     "Action": ["events:PutRule", "events:PutTargets", "events:DeleteRule", "events:RemoveTargets",
      "events:EnableRule", "events:DisableRule"]},
    {"Sid": "HealthCheck", "Effect": "Allow", "Resource": "*",
     "Action": ["route53:CreateHealthCheck", "route53:UpdateHealthCheck", "route53:DeleteHealthCheck",
      "route53:ChangeTagsForResource"]}
  ]
}
EOF
)

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # 버전은 최대 5개: 기본 아닌 가장 오래된 버전 정리 후 새 기본 버전 등록
  old=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`]|[-1].VersionId' --output text)
  [ "$old" != None ] && aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$old"
  aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$DOC" --set-as-default >/dev/null
else
  aws iam create-policy --policy-name voc-llm-admin --policy-document "$DOC" \
    --tags Key=Project,Value=voc-llm >/dev/null
fi

if ! aws iam get-user --user-name "$USER" >/dev/null 2>&1; then
  aws iam create-user --user-name "$USER" --tags Key=Project,Value=voc-llm >/dev/null
fi
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN"

# 액세스 키: 처음 1회만 발급해 로컬 프로필 voc-llm 에 저장 (화면에 출력하지 않는다)
if [ "$(aws iam list-access-keys --user-name "$USER" --query 'length(AccessKeyMetadata)' --output text)" = 0 ]; then
  read -r KID SECRET < <(aws iam create-access-key --user-name "$USER" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text | tr -d '\r')
  aws configure set aws_access_key_id "$KID" --profile voc-llm
  aws configure set aws_secret_access_key "$SECRET" --profile voc-llm
  aws configure set region "$REGION" --profile voc-llm
  echo "액세스 키 발급, 로컬 프로필 voc-llm 에 저장 ($KID)"
fi
echo "완료: 사용자 $USER, 정책 $POLICY_ARN"
