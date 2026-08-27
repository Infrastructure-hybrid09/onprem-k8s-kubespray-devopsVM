# firewalld 원상복구와 Calico 호환 모드

## 결론

Calico의 공식 시스템 요구사항은 노드에서 firewalld 같은 별도 iptables
관리자를 비활성화하라고 안내한다. 따라서 이 프로젝트의 **공식 권장 운영
모드도 firewalld 비활성화**다.

교육 환경에서 방화벽 서비스를 반드시 켜야 할 때만
`38-manage-k8s-firewalld.sh`의 호환 모드를 사용한다. 이 모드는 기존
`nw-mgmt`, `nw-internal`, `nw-data` zone과 rich rule을 수정하지 않는다.
스크립트가 소유하는 짧은 이름의 zone/policy 여섯 개만 추가·제거한다.

- `k8s-pods`: Pod CIDR `10.244.0.0/16`을 source로 묶되 zone target은
  `DROP`으로 둔다. 필요한 방향만 아래 policy로 연다.
- `k8s-vxlan-in`: 여섯 Kubernetes Internal IP 사이의 VXLAN UDP/4789를
  `nw-internal -> HOST` 방향으로 허용한다.
- `k8s-to-pods`: LB1/2 및 여섯 Kubernetes 노드에서 Pod CIDR로 전달되는
  트래픽을 허용한다. NodePort DNAT 뒤의 LB-to-Pod 트래픽도 여기에 포함된다.
- `k8s-host-pods`: 각 노드의 kubelet probe 및 Control Plane 프로세스가
  로컬/원격 Pod CIDR로 통신하도록 `HOST -> k8s-pods`를 허용한다.
- `k8s-pod-out`: Pod에서 다른 zone으로 전달되는 트래픽을 허용한다. 실제
  workload 간/외부 egress 제한은 Calico NetworkPolicy로 정의해야 한다.
- `k8s-pod-host`: Pod에서 Kubernetes node host로 가는 경로는 NodeLocal
  DNS TCP/UDP 53, Kubernetes Service CIDR `10.96.0.0/12`, direct API
  TCP/6443, Node Exporter TCP/9100, kubelet TCP/10250만 허용한다. IPVS가
  모든 ClusterIP를 local VIP로 생성하므로 API VIP 하나만 열어서는 안 된다.

근거는 [Calico 시스템 요구사항](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements),
[firewalld policy 문서](https://firewalld.org/documentation/man-pages/firewalld.policies),
[RHEL 9 zone 간 전달 정책](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_firewalls_and_packet_filters/using-and-configuring-firewalld_firewall-packet-filters#filtering-forwarded-traffic-between-zones_using-and-configuring-firewalld)이다.

## 팀의 기존 1차 정책과의 차이

기존 `firewalld_setup.sh`가 만든 `nw-mgmt`, `nw-internal`, `nw-data`와 모든
VM별 rich rule은 그대로 보존한다. 다만 Kubernetes 노드에서는 다음 세
항목만으로 Pod 경로를 완성할 수 없다.

- `nw-internal`의 `source 10.244.0.0/16 accept`는 zone INPUT 허용일 뿐,
  `target=DROP`인 zone 사이의 NodePort DNAT/FORWARD를 모두 허용하지 않는다.
- Worker에만 있는 UDP/4789 규칙으로는 VXLAN의 양방향 CP/Worker 통신을
  보장하지 못한다.
- 실행 중인 Kubernetes 노드에서 `firewall-cmd --reload`를 반복하면
  Calico/kube-proxy가 관리하는 경로를 다시 검증해야 하므로 중앙 호환
  entrypoint는 reload를 사용하지 않는다.

현재 클러스터에는 NodeLocal DNS가 있으므로 Pod에서 node host 방향의
TCP/UDP 53도 반드시 포함한다. 기존 1차 정책 파일을 다시 실행해 문제를
덮지 말고, 원본 정책 위에 이 문서의 별도 policy 객체를 적용한다.

## 실행 위치와 action

모든 명령은 PC2 DevOps VM의 `devops` 계정에서 프로젝트 루트를 현재
디렉터리로 두고 실행한다. 원격 접속은 고정된
`k8sadmin`/`~/.ssh/neuroplan_k8s`만 사용하며 대상은 CP1~3와 Worker1~3
정확히 여섯 대다.

| action | 변경 여부 | 결과 |
|---|---:|---|
| `status` | 없음 | 여섯 노드의 service/managed state 조회 |
| `restore-original` | 있음 | 호환 객체를 제거하고 기존 영구 firewalld 설정만 활성화 |
| `apply-k8s` | 있음 | 기존 설정을 보존하고 Kubernetes 호환 객체를 추가한 뒤 활성화 |
| `verify` | 임시 smoke Pod/Service 생성 후 삭제 | 새 SSH, host API, Pod DNS/ClusterIP, NodePort/VXLAN, Calico/CoreDNS/Metrics 검증 |
| `rollback-k8s` | 있음 | 호환 객체를 제거하고 Calico 권장 `disabled/inactive` 상태로 복귀 |

## 1. 현재 상태 확인

```bash
cd ~/onprem-k8s
./07-troubleshooting/38-manage-k8s-firewalld.sh status
```

## 2. 기존 방화벽만 원상복구

사용자가 실행한 `systemctl disable --now firewalld`는 영구 zone/rich rule을
삭제하지 않았으므로 원상복구의 핵심은 `systemctl enable --now firewalld`다.
아래 action은 이를 여섯 노드에 순차 적용한다. 이전에 이 스크립트의 호환
객체를 적용했다면 그 객체만 먼저 제거한다.

```bash
CONFIRM_FIREWALLD=restore-original \
  ./07-troubleshooting/38-manage-k8s-firewalld.sh restore-original
```

이 상태는 기존 `nw-internal`의 `target: DROP`, `forward: no`도 그대로
복원하므로 기존 Pod-to-Service/API 장애가 다시 발생할 수 있다. 이는
Kubernetes 정상 운영 완료 상태가 아니라 **원본 방화벽 상태 확인용**이다.

## 3. 방화벽을 켠 Kubernetes 호환 모드 적용

```bash
CONFIRM_FIREWALLD=apply-k8s \
  ./07-troubleshooting/38-manage-k8s-firewalld.sh apply-k8s
```

스크립트는 다음 순서로 동작한다.

1. firewalld가 꺼진 기준 상태에서 여섯 노드 Ready,
   Calico/CoreDNS/Metrics와 Metrics API가 모두 정상인지 먼저 확인한다.
   기준 상태가 비정상이면 방화벽을 한 대도 변경하지 않고 중단한다.
2. DevOps 중앙 제어 gate와 정확한 Management SSH 허용 rule을 확인한다.
3. firewalld policy 지원, nftables backend, `StrictForwardPorts` 충돌 여부를
   확인한다.
4. 노드마다 `/var/backups/neuroplan-firewalld/`에 기존 설정과 상태를
   백업한다.
5. firewalld가 중지된 상태에서 `firewall-offline-cmd`로 전용 객체만
   구성하고 `--check-config`를 통과시킨다.
6. `cp1 -> cp2 -> cp3 -> worker1 -> worker2 -> worker3` 순서로 한 대씩
   firewalld를 활성화한다.
7. 각 노드에 **새 SSH 연결**을 만들고 direct API, API VIP, ClusterIP API를
   확인한다.
8. 여섯 노드 Ready, Calico/CoreDNS/Metrics, 임시 Pod의 DNS와
   `kubernetes.default.svc` 경로를 확인한다.
9. Worker3의 임시 client Pod에서 Worker1의 임시 일반 ClusterIP Service를
   먼저 호출한다. 기존 고정 NodePort 정책은 바꾸지 않고, Worker2에 CP1
   source와 임의 검증 포트 하나만 허용하는 120초 runtime rule을 만든 뒤
   CP1에서 Worker2의 임시 NodePort를 거쳐 Worker1 Pod로 요청한다. 이 과정은
   일반 Service CIDR, NodePort DNAT, zone 간 FORWARD와 cross-node VXLAN을
   함께 검사하며 임시 rule은 즉시 제거한다.
10. 모든 검증이 성공한 경우에만 자동 안전 타이머를 취소하고, 취소 직후
   여섯 노드의 `enabled/active` 상태를 다시 확인한다.

적용 중 SSH나 클러스터 검증이 실패하면 아직 취소되지 않은 타이머가 최대
15분 안에 해당 노드의 firewalld를 자동 비활성화한다. 콘솔 접근 경로는
적용 전에 반드시 확보한다.

## 4. 적용 후 재검증

```bash
./07-troubleshooting/38-manage-k8s-firewalld.sh verify
./06-validation/23-verify-cluster.sh
./06-validation/24-verify-network.sh
```

`verify`가 성공해야 다음 조건이 모두 성립한다.

- 여섯 노드에서 firewalld가 `enabled/active`
- direct API `192.168.34.31:6443`, API VIP
  `192.168.34.100:6443`, ClusterIP API `10.96.0.1:443` 응답
- 노드 6대 `Ready`
- Calico node, Calico controller, CoreDNS, Metrics Server 정상
- Metrics API `Available=True`와 `kubectl top nodes` 성공
- Pod 내부 DNS 및 `kubernetes.default.svc` 접속 성공
- Worker3 Pod -> 일반 ClusterIP Service -> Worker1 Pod 요청 성공
- CP1 -> Worker2 NodePort -> Worker1 Pod cross-node 요청 성공

## 5. 호환 객체 제거와 원복

```bash
CONFIRM_FIREWALLD=rollback-k8s \
  ./07-troubleshooting/38-manage-k8s-firewalld.sh rollback-k8s
```

스크립트 state가 소유권을 증명한 `k8s-pods`, `k8s-vxlan-in`,
`k8s-to-pods`, `k8s-host-pods`, `k8s-pod-out`, `k8s-pod-host`만
제거한다. 기존 `nw-*` zone, interface, service, port, rich rule은
삭제하거나 덮어쓰지 않는다. rollback 후에는
Calico 공식 권장 상태인 firewalld `disabled/inactive`로 돌아간다. 기존
영구 정책 자체를 다시 켜야 할 때만 별도의 `restore-original`을 사용한다.

## 보안 및 운영 제한

- 물리 스위치/VMware 네트워크에서 `10.244.0.0/16` source spoofing을
  차단해야 한다.
- `k8s-pod-out`은 전달 트래픽을 허용할 뿐 workload default-deny를 자동
  생성하지 않는다. namespace별 Calico/Kubernetes NetworkPolicy가 없으면
  Pod egress와 Pod 간 통신은 허용 상태다.
- Pod에서 node host로의 접근은 NodeLocal DNS TCP/UDP 53, Kubernetes
  Service CIDR `10.96.0.0/12`, direct API TCP/6443, Node Exporter TCP/9100,
  kubelet TCP/10250만 연다. Service 간 세부 제한은 Kubernetes/Calico
  NetworkPolicy가 담당한다. 추가 host port가 필요하면 팀 승인과 별도 검증
  후 policy를 변경한다.
- VXLAN Always 구성만 대상으로 하므로 TCP/179(BGP)를 새로 열지 않는다.
- `FirewallBackend=iptables` 또는 `StrictForwardPorts=yes`이면 적용하지 않는다.
- 실행 중 임의의 `firewall-cmd --reload`/`--complete-reload`를 하지 않는다.
  방화벽 변경 후에는 항상 이 문서의 전체 검증을 다시 수행한다.
- `apply-k8s` 최초 실행은 firewalld가 inactive인 상태에서 시작한다. 이미
  호환 state가 있는 재시도만 active 상태에서 검증·재수렴할 수 있다.
- Network 담당 규칙은 반드시 permanent로 관리한다. runtime-only 규칙을
  만든 상태에서 이 스크립트를 실행하지 않는다.
- 프로덕션 또는 평가 기준이 Calico 공식 지원 구성을 요구하면 firewalld를
  비활성화하고 Calico HostEndpoint/GlobalNetworkPolicy로 host 정책을 옮긴다.
