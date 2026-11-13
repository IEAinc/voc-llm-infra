#!/usr/bin/env bash
# EC2(Ubuntu 24.04)에서 root 로 실행: sudo bash ec2/install.sh
# 여러 번 실행해도 안전하다. 처음 실행 시 /opt/voc-llm/.env 를 만들고 멈춘다 → 값을 채우고 다시 실행.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
APP=/opt/voc-llm

install -d -m 755 "$APP/bin" "$APP/state" /var/log/voc-llm /etc/nginx/voc-llm
if [ ! -f "$APP/.env" ]; then
  # 로컬에서 미리 채운 ec2/.env(git 제외)가 함께 복사됐으면 그것을, 없으면 템플릿을 쓴다
  if [ -f "$SRC/.env" ]; then install -m 600 "$SRC/.env" "$APP/.env"; else install -m 600 "$SRC/.env.example" "$APP/.env"; fi
  echo "생성됨: $APP/.env  → 빈 값을 채운 뒤 install.sh 를 다시 실행하세요."
  exit 1
fi
set -a; . "$APP/.env"; set +a
: "${DOMAIN:?.env 에 DOMAIN 필요}" "${CERT_EMAIL:?.env 에 CERT_EMAIL 필요}" "${VLLM_API_KEY:?.env 에 VLLM_API_KEY 필요}"
: "${RUNPOD_API_KEY:?.env 에 RUNPOD_API_KEY 필요}" "${VLLM_IMAGE:?.env 에 VLLM_IMAGE 필요}"
case "$VLLM_IMAGE" in *v0.0.0*) echo ".env 의 VLLM_IMAGE 가 자리표시자(v0.0.0)입니다. 실제 태그로 바꾸세요." >&2; exit 1 ;; esac

# 시간대 (cron 이 KST 로 동작하도록)
timedatectl set-timezone Asia/Seoul

# 패키지
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx jq curl certbot gettext-base util-linux stress-ng
command -v aws >/dev/null || snap install aws-cli --classic

# 스왑 1GB
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 애플리케이션 파일 (gpu-priority, holidays 는 저장소가 원본이므로 항상 덮어쓴다)
install -m 755 "$SRC"/bin/*.sh "$APP/bin/"
install -m 644 "$SRC/gpu-priority.txt" "$SRC/holidays.txt" "$APP/"

# 인증서 (최초 1회 standalone 발급. 갱신 시 nginx 를 잠깐 멈췄다 다시 띄운다)
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  systemctl stop nginx || true
  certbot certonly --standalone -d "$DOMAIN" -m "$CERT_EMAIL" --agree-tos -n \
    --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
fi

# nginx
rm -f /etc/nginx/sites-enabled/default
(umask 077; envsubst '${DOMAIN} ${VLLM_API_KEY}' < "$SRC/conf/nginx/voc-llm.conf.tmpl" > /etc/nginx/conf.d/voc-llm.conf)
chmod 600 /etc/nginx/conf.d/voc-llm.conf
if [ ! -f /etc/nginx/voc-llm/client_keys.conf ]; then
  KEY=$(openssl rand -hex 32)
  install -m 600 /dev/null /etc/nginx/voc-llm/client_keys.conf
  { cat "$SRC/conf/nginx/client_keys.conf.example"; echo "\"Bearer $KEY\" 1;"; } > /etc/nginx/voc-llm/client_keys.conf
  echo "고객사 API 키(최초 생성, 고객사에 전달 후 이 화면 기록은 지우세요): $KEY"
fi
[ -f /etc/nginx/voc-llm/upstream.conf ] || VOC_NO_RELOAD=1 bash -c ". $APP/bin/lib.sh; upstream_off"
install -D -m 644 "$SRC/conf/systemd/nginx-override.conf" /etc/systemd/system/nginx.service.d/override.conf
systemctl daemon-reload

# cron, logrotate, journald
install -m 644 "$SRC/conf/cron/voc-llm" /etc/cron.d/voc-llm
install -m 644 "$SRC/conf/logrotate/voc-llm" /etc/logrotate.d/voc-llm
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/size.conf

systemctl restart systemd-journald
systemctl enable nginx cron
systemctl restart cron
nginx -t
systemctl restart nginx

# CloudWatch Agent
CWA=/opt/aws/amazon-cloudwatch-agent
if [ ! -x "$CWA/bin/amazon-cloudwatch-agent-ctl" ]; then
  curl -sSfo /tmp/cwa.deb https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
  dpkg -i /tmp/cwa.deb
fi
install -D -m 644 "$SRC/conf/cloudwatch/amazon-cloudwatch-agent.json" "$CWA/etc/amazon-cloudwatch-agent.json"
"$CWA/bin/amazon-cloudwatch-agent-ctl" -a fetch-config -m ec2 -s -c "file:$CWA/etc/amazon-cloudwatch-agent.json"
systemctl enable amazon-cloudwatch-agent

# 공휴일 최초 갱신 (실패해도 설치는 계속. 실패 시 이번 주는 평일 모두 운영)
"$APP/bin/holiday-sync.sh" || echo "공휴일 갱신 실패: HOLIDAY_API_KEY 확인 후 $APP/bin/holiday-sync.sh 재실행"

echo "install 완료. 고객사 키 추가/교체: /etc/nginx/voc-llm/client_keys.conf 수정 후 'systemctl reload nginx'"
