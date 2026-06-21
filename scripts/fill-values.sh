#!/usr/bin/env bash
# Fill the <ACCOUNT_ID> and <ACM_CERT_ARN> placeholders in the Helm env values and the
# gateway from the rentlora-infra Terraform outputs. Run this once after `terraform apply`.
#
# Usage:
#   scripts/fill-values.sh [path-to-rentlora-infra]
# Defaults to ../rentlora-infra (sibling checkout). Requires terraform + AWS access to read
# the remote state outputs.
set -euo pipefail

HELM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA="${1:-$HELM_ROOT/../rentlora-infra}"
CLUSTER="$INFRA/stacks/cluster"

[ -d "$CLUSTER" ] || { echo "ERROR: cluster stack not found at $CLUSTER (pass the infra path as arg 1)"; exit 1; }

echo "Reading Terraform outputs from $CLUSTER ..."
REGISTRY="$(cd "$CLUSTER" && terraform output -raw ecr_registry)"   # <acct>.dkr.ecr.<region>.amazonaws.com
ACCOUNT="${REGISTRY%%.*}"
ACM_ARN="$(cd "$CLUSTER" && terraform output -raw acm_cert_arn)"

[[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo "ERROR: could not parse account id from '$REGISTRY'"; exit 1; }
[ -n "$ACM_ARN" ] || { echo "ERROR: empty acm_cert_arn output"; exit 1; }
echo "  account = $ACCOUNT"
echo "  acm arn = $ACM_ARN"

# Role names (rentlora-eks-<env>-<svc>) and the ECR region are already correct in the
# Point the env values at this account. The charts DERIVE the ECR registry and each
# IRSA role ARN from global.accountId, so only these two values need setting (idempotent
# — safe to re-run when switching accounts).
for env in dev prod; do
  f="$HELM_ROOT/environments/$env/values.yaml"
  [ -f "$f" ] || { echo "  skip (missing): $f"; continue; }
  yq -i ".global.accountId = \"$ACCOUNT\"" "$f"
  yq -i ".acmCertArn = \"$ACM_ARN\""       "$f"
  echo "  set accountId + acmCertArn in environments/$env/values.yaml"
done

# Gateway is applied via kubectl (not Helm), so its ACM cert ARN must be a literal.
gw="$HELM_ROOT/gateway/gatewayparameters.yaml"
if [ -f "$gw" ]; then
  sed -i -E "s#(aws-load-balancer-ssl-cert: ).*#\1\"$ACM_ARN\"#" "$gw"
  echo "  set ACM cert in gateway/gatewayparameters.yaml"
fi

echo
echo "Done. Review and commit:"
echo "  git -C \"$HELM_ROOT\" diff"
echo "  git -C \"$HELM_ROOT\" commit -am 'fill account id + ACM arn from terraform outputs' && git push"
