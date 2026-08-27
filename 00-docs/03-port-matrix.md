# 필수 포트 매트릭스

| Source | Destination | Protocol/Port | Purpose | 담당 |
|---|---|---|---|---|
| PC5 Windows 작업석의 승인된 source IP | DevOps 192.168.14.21 | TCP 22 | VS Code Remote-SSH 진입점 | Network/A |
| CP/Worker Management | DevOps 192.168.14.21 | TCP 22 | 최초 console bootstrap용 script/public key SCP pull | Network/A |
| DevOps 192.168.14.21 | CP/Worker Management | TCP 22 | Ansible SSH | Network/DevOps |
| DevOps 192.168.14.21 | 승인된 LB/DB/NFS/Infra Management | TCP 22 | ProxyJump 기반 담당자 원격 작업 | 각 VM 담당/Network |
| LB1/LB2 Internal 192.168.34.11/.12 | CP1~3 Internal | TCP 6443 | API backend | Network |
| CP/Worker | API VIP 192.168.34.100 | TCP 6443 | Kubernetes API | Network/A |
| CP1~3 | CP1~3 Internal | TCP 2379-2380 | etcd client/peer | Network/A |
| CP1~3 | CP/Worker Internal | TCP 10250 | kubelet API | Network/A |
| CP/Worker 상호 | CP/Worker Internal | UDP 4789 | Calico VXLAN | Network/A |
| Pod CIDR 10.244.0.0/16 | CP/Worker host | TCP/UDP 53, TCP 6443, 9100, 10250 | NodeLocal DNS, Kubernetes API, Node Exporter, kubelet host endpoint 접근 | Network/A |
| Pod CIDR 10.244.0.0/16 | Service CIDR 10.96.0.0/12 | Service가 정의한 protocol/port | IPVS local VIP 경로를 firewalld에서 허용하고 세부 제한은 NetworkPolicy에 위임 | Network/A |
| Pod CIDR 10.244.0.0/16 | Pod/승인 외부 목적지 | Calico가 허용한 protocol/port | firewalld는 전달을 허용하고 workload 정책을 Calico에 위임 | Network/A |
| LB1/LB2 및 CP/Worker Internal | Pod CIDR 10.244.0.0/16 | 승인된 Kubernetes/NodePort 전달 트래픽 | firewalld zone 간 FORWARD/DNAT 허용 | Network/A |
| LB1/LB2 Internal 192.168.34.11/.12 | Worker1~3 Internal | TCP 30443 | NGF HTTPS NodePort | Network/A |
| CP/Worker | DevOps Internal | TCP 5000 | Private Registry pull | Network/DevOps |
| CP/Worker | Infra DNS/NTP 192.168.14.62 | TCP/UDP 53, UDP 123 | DNS/NTP | Network |
| Infra 192.168.14.62 | 승인된 public/upstream NTP | UDP 123 | Infra 기준시각 동기화 | Infra/Network |
| DevOps/CP/Worker | Internet via Infra | TCP 80/443 | Git/RPM/image | Network |

NodePort 전체 범위나 Control Plane 로컬 포트 `10257/10259`를 불필요하게 개방하지 않는다.
firewalld를 활성화하는 경우 단순 INPUT port 허용만으로는 충분하지 않다.
Pod CIDR source와 DNAT 후 Pod 목적지의 FORWARD 정책은
`08-firewalld-calico-compatibility.md`를 기준으로 적용한다.
