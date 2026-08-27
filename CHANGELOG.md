# 변경 이력

## v1.0.1 — 2026-08-27

- v1.0.0으로 검증한 Kubespray 및 Kubernetes 플랫폼의 운영 기준을 재확인했다.
- Canonical Kubernetes API endpoint를 `https://192.168.34.100:6443`으로 명시했다.
- 서비스 공개 진입점을 `https://app.nplan.local` 및 Service VIP `192.168.24.100:443`으로 정리했다.
- Kubernetes 내부 서비스 DNS `neuroplan.local`과 Infra BIND DNS `nplan.local`의 역할 분리를 문서에 반영했다.
- 플랫폼 구성요소의 실제 버전은 변경하지 않았다.

## v1.0.0

- Kubespray v2.31.0 기반의 3 Control Plane / 3 Worker 고가용성 Kubernetes 클러스터 구축 기준을 확정했다.
- Kubernetes v1.35.4, containerd v2.2.3, Calico v3.31.5, NGINX Gateway Fabric v2.6.7을 검증 기준으로 고정했다.
