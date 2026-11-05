#!/usr/bin/env bash
set -euo pipefail

BASE_URL='https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com'

STATUS=0
echo ""
echo "Testing endpoints against: $BASE_URL"
echo ""

for endpoint in '' docker secret_word loadbalanced tls; do
  echo "URL: $BASE_URL/$endpoint"
  curl -k --fail-with-body --show-error --connect-timeout 20 "$BASE_URL/$endpoint" || STATUS=1
  echo ""
done

exit "$STATUS"