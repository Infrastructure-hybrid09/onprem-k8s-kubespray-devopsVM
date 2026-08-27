#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

EXPECTED_GATEWAY_API="v1.5.1"
NAMESPACE="application"
APP_FQDN="app.nplan.local"
SERVICE_VIP="192.168.24.100"
DNS_SERVER="192.168.14.62"

command -v dig >/dev/null || {
  echo "required command not found: dig" >&2
  exit 1
}
mapfile -t app_answers < <(
  dig @"$DNS_SERVER" "$APP_FQDN" A +short |
    sed '/^[[:space:]]*$/d'
)
[[ "${#app_answers[@]}" -eq 1 && "${app_answers[0]}" == "$SERVICE_VIP" ]] || {
  echo "$DNS_SERVER answered ${app_answers[*]:-nothing} for $APP_FQDN" >&2
  exit 1
}
echo "[PASS] Infra BIND resolves $APP_FQDN only to $SERVICE_VIP"

for crd in gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io; do
  actual="$(kubectl get crd "$crd" \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
  [[ "$actual" == "$EXPECTED_GATEWAY_API" ]] || { echo "$crd=$actual" >&2; exit 1; }
done
echo "[PASS] Gateway API standard bundle $EXPECTED_GATEWAY_API"

helm -n nginx-gateway status ngf >/dev/null
helm -n nginx-gateway list | grep -Eq '2\.6\.7'
kubectl -n nginx-gateway rollout status deployment/ngf-nginx-gateway-fabric --timeout=5m
controller_json="$(kubectl -n nginx-gateway get deployment ngf-nginx-gateway-fabric -o json)"
jq -e '.spec.replicas == 2 and .status.availableReplicas == 2' \
  <<<"$controller_json" >/dev/null
controller_pods="$(kubectl -n nginx-gateway get pod \
  -l app.kubernetes.io/name=nginx-gateway-fabric,app.kubernetes.io/instance=ngf \
  -o json)"
jq -e '([.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .spec.nodeName] | unique | length) == 2' \
  <<<"$controller_pods" >/dev/null
echo "[PASS] NGF Helm release 2.6.7, two controllers on separate Workers"

kubectl get gatewayclass nginx \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' | grep -Fxq True
kubectl -n "$NAMESPACE" get gateway neuroplan-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' | grep -Fxq True
kubectl -n "$NAMESPACE" get gateway neuroplan-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' | grep -Fxq True

route_json="$(kubectl -n "$NAMESPACE" get httproute validation-echo -o json)"
jq -e 'any(.status.parents[]?.conditions[]?; .type == "Accepted" and .status == "True")' \
  <<<"$route_json" >/dev/null
jq -e 'any(.status.parents[]?.conditions[]?; .type == "ResolvedRefs" and .status == "True")' \
  <<<"$route_json" >/dev/null
echo "[PASS] GatewayClass, Gateway and HTTPRoute conditions"

service_json="$(kubectl -n "$NAMESPACE" get service -o json)"
jq -e 'any(.items[]; .spec.type == "NodePort" and .spec.externalTrafficPolicy == "Cluster" and any(.spec.ports[]?; .port == 443 and .nodePort == 30443))' \
  <<<"$service_json" >/dev/null
echo "[PASS] NGF service maps listener 443 to NodePort 30443"

data_deployments="$(kubectl -n "$NAMESPACE" get deployment \
  -l gateway.networking.k8s.io/gateway-name=neuroplan-gateway -o json)"
jq -e '.items | length == 1 and .[0].spec.replicas == 3 and .[0].status.availableReplicas == 3' \
  <<<"$data_deployments" >/dev/null
data_pods="$(kubectl -n "$NAMESPACE" get pod \
  -l gateway.networking.k8s.io/gateway-name=neuroplan-gateway -o json)"
jq -e '([.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .spec.nodeName] | unique | length) == 3' \
  <<<"$data_pods" >/dev/null
echo "[PASS] three NGF data-plane replicas are Ready on three Workers"

for ip in 192.168.34.41 192.168.34.42 192.168.34.43; do
  response="$(curl -ksS --connect-timeout 5 --max-time 15 \
    --resolve "$APP_FQDN:30443:$ip" \
    "https://$APP_FQDN:30443/validation")"
  grep -Fq validation-ok <<<"$response"
  echo "[PASS] Worker NodePort $ip:30443"
done

response="$(curl -ksS --connect-timeout 5 --max-time 15 \
  --resolve "$APP_FQDN:443:$SERVICE_VIP" \
  "https://$APP_FQDN/validation")"
grep -Fq validation-ok <<<"$response"
echo "[PASS] Service VIP $SERVICE_VIP:443 full path"
