# 전체 설계 요약

## 고정 원칙

- 기존 VMware NIC와 IP 설정을 변경하지 않는다.
- CP1~CP3와 Worker1~Worker3는 각각 독립 VM이다.
- DevOps VM은 Kubernetes 노드가 아니다.
- Ansible SSH는 Management `192.168.14.0/24`, Kubernetes 노드 통신은 Internal `192.168.34.0/24`를 사용한다.
- 외부 HAProxy/Keepalived의 API VIP `https://192.168.34.100:6443`을 유일한 canonical API endpoint로 사용한다.
- 사용자 트래픽은 `192.168.24.100:443`에서 Worker `30443/TCP`으로 전달한다.
- MetalLB, kube-vip, Kubespray registry/Argo CD/스토리지 provisioner를 활성화하지 않는다.
- Kubernetes Secret은 Kubespray `secretbox` encryption provider로 etcd 저장 전에 암호화한다.
- 암호화 credential은 Git/NFS snapshot과 분리해 접근 통제된 암호화 저장소에 백업한다.

## 노드 매트릭스

| 노드 | 역할 | Management | Internal | Data | 물리 호스트 |
|---|---|---:|---:|---:|---|
| CP1 | Control Plane + etcd1 | 192.168.14.31 | 192.168.34.31 | - | PC1 |
| CP2 | Control Plane + etcd2 | 192.168.14.32 | 192.168.34.32 | - | PC2 |
| CP3 | Control Plane + etcd3 | 192.168.14.33 | 192.168.34.33 | - | PC3 |
| Worker1 | Worker | 192.168.14.41 | 192.168.34.41 | 192.168.44.41 | PC1 |
| Worker2 | Worker | 192.168.14.42 | 192.168.34.42 | 192.168.44.42 | PC2 |
| Worker3 | Worker | 192.168.14.43 | 192.168.34.43 | 192.168.44.43 | PC3 |
| DevOps | Ansible/Kubespray/Registry | 192.168.14.21 | 192.168.34.21 | 192.168.44.21 | PC2 |

## 외부 의존 VM/VIP 기준 정보

아래 주소는 첨부 설계와의 연동 기준이며 이 저장소가 설정을 변경하지 않는다.

| 구성요소 | Management | DMZ | Internal | Data/Outside | 물리 호스트 |
|---|---:|---:|---:|---:|---|
| LB1 MASTER | 192.168.14.11 | 192.168.24.11 | 192.168.34.11 | - | PC1 |
| LB2 BACKUP | 192.168.14.12 | 192.168.24.12 | 192.168.34.12 | - | PC3 |
| MariaDB Primary | 192.168.14.51 | - | - | 192.168.44.51 | PC4 |
| MariaDB Replica | 192.168.14.52 | - | - | 192.168.44.52 | PC5 |
| NFS Backup | 192.168.14.61 | - | - | 192.168.44.61 | PC4 |
| Infra DNS/NTP/NAT | 192.168.14.62 | - | 192.168.34.62 | 192.168.44.62 / 10.1.93.86 | PC5 |
| Kubernetes API VIP | - | - | 192.168.34.100:6443 | - | LB HA Pair |
| Application Service VIP | - | 192.168.24.100:443 | - | - | LB HA Pair |

DevOps VM의 Data `192.168.44.21:4006`은 MaxScale 담당 endpoint로 예약하며 Kubernetes 설치 코드가 bind하거나 변경하지 않는다.

## `/etc/hosts` 이름 규칙

DevOps와 CP1~3/Worker1~3에는 `02-ansible/templates/hosts.j2`로 동일한 4-Zone 기준 파일을 배포한다. 기존 파일은 변경 전에 Ansible backup으로 보존한다. 이 작업은 이름 해석 파일만 관리하며 NIC/IP/route를 변경하지 않고, LB/DB/NFS/Infra VM 자체에도 접속하거나 파일을 쓰지 않는다.

| Zone | FQDN 예 | alias 규칙 | 용도 |
|---|---|---|---|
| Management `192.168.14.0/24` | `cp1.nplan.local` | `cp1`, `worker1`, `lb1` 등 bare alias | SSH/Ansible/관리 |
| DMZ `192.168.24.0/24` | `lb1.dmz.nplan.local` | `lb1-dmz` | 외부 Client의 LB 진입 |
| Internal `192.168.34.0/24` | `cp1.k8s.nplan.local` | `cp1-k8s`, `worker1-k8s` | Kubernetes 노드/API 통신 |
| Data `192.168.44.0/24` | `worker1.data.nplan.local` | `worker1-data` | DB/NFS/스토리지/Backend 데이터 |

같은 bare alias를 여러 네트워크에 재사용하지 않는다. 따라서 `cp1`은 항상 `192.168.14.31`, `cp1-k8s`는 항상 `192.168.34.31`로 해석된다. API는 FQDN을 canonical endpoint로 사용하지 않으며 VIP IP `192.168.34.100`으로 고정한다. 과거 이름은 롤백 호환 목적으로만 남길 수 있고 운영 의존성으로 취급하지 않는다.

Kubespray `cluster_name: neuroplan.local`은 Kubernetes DNS domain으로도
사용한다. 따라서 Service FQDN은
`<service>.<namespace>.svc.neuroplan.local`이며 `svc.cluster.local`을
사용하지 않는다. 이 `neuroplan.local`은 Infra BIND의 `nplan.local`과
의도적으로 분리한 Kubernetes 내부 권한 영역이다. 기존 클러스터의
CoreDNS, NodeLocal DNS, kubelet clusterDomain과 ServiceAccount issuer를
`nplan.local`로 일괄 변경하지 않는다.

## 첨부 구성도와 명시 요구의 충돌 처리

물리 구성도 일부에는 Worker Data `192.168.44.41~43:30443` 표기가 있지만, 사용자가 이번 구축 요청에서 지정한 HAProxy backend는 Worker Internal `192.168.34.41~43:30443`이다. 실행 inventory, NGF 검증, 포트 매트릭스는 더 직접적인 최신 요청인 **Internal backend**를 기준으로 통일했다. Network 담당자는 HAProxy 적용 전 이 결정을 공동 확인한다.

## 트래픽 경로

```text
Kubernetes API
192.168.34.100:6443
  -> external HAProxy
  -> CP1/CP2/CP3 192.168.34.31~33:6443

Application HTTPS
192.168.24.100:443
  -> external HAProxy
  -> Worker1/Worker2/Worker3 192.168.34.41~43:30443
  -> NGINX Gateway Fabric
  -> HTTPRoute
  -> ClusterIP Service
  -> Application Pods
```

## CIDR

- Pod CIDR: `10.244.0.0/16`
- Service CIDR: `10.96.0.0/12`
- Calico overlay: VXLAN, `4789/UDP`
- Private Registry: `192.168.34.21:5000`

Worker의 Data `192.168.44.41~43`은 향후 DB/스토리지 트래픽 식별용 label에만 기록한다. kubelet `InternalIP`, etcd, Calico와 Kubernetes API 통신에는 사용하지 않으며 이 저장소가 Data NIC의 route를 만들지 않는다.

## HA 검증 범위

- PC1 장애: CP1, Worker1, LB1 손실 상황에서 API/애플리케이션 서비스 지속
- PC3 장애: CP3, Worker3, LB2 손실 상황에서 API/애플리케이션 서비스 지속
- PC2는 DevOps VM이 있으므로 물리 호스트 장애 시연 대상에서 제외
- etcd quorum은 3개 중 2개가 정상이어야 한다.
