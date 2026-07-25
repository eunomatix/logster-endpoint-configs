# logster-endpoint-configs

Baseline endpoint configuration for [Logster](https://docs.eunomatix.com/logster/)
— the collector and shipper configuration files that run on each monitored
Windows and Linux endpoint.

These are the exact files referenced by the
[Logster documentation](https://docs.eunomatix.com/logster/). They are
published here so you can review what Logster monitors before deploying it,
diff a tuned deployment against the shipped baseline, and pull updates
without waiting for a new release package.

> This repository contains **configuration only** — no collector binaries.
> The Linux eBPF sensor is distributed as a `.deb` / `.rpm` release package;
> see the endpoint installation guides in the documentation.

## Contents

| File | Installs to | Purpose |
| --- | --- | --- |
| [`linux/auditd/audit.rules`](linux/auditd/audit.rules) | `/etc/audit/rules.d/logster.rules` | Audit daemon ruleset — 328 active rules covering privilege escalation, persistence, credential access, kernel tampering, and attacker tooling. Based on Florian Roth's *Linux Audit Daemon — Best Practice Configuration* with Logster tuning. |
| [`linux/ebpf-sensor/filter.json`](linux/ebpf-sensor/filter.json) | `/etc/logster/ebpf-sensor/filter.json` | Runtime filter for the Logster eBPF sensor — which process, file, and network events are captured, dropped, or flagged as security-relevant. Operator-editable; not overwritten on package upgrade. |
| [`linux/rsyslog/kafka-shipper.conf.in`](linux/rsyslog/kafka-shipper.conf.in) | `/etc/rsyslog.d/60-logster-kafka-shipper.conf` | rsyslog `imfile` + `omkafka` shipper template — tails the auditd and eBPF sensor logs and publishes them to the App Node's Kafka listener. Rendered from this template by `logster-sensor-setup --brokers <host:port>`; also the reference for the JSON envelope if you ship with a different agent. |
| [`windows/sysmon-config.xml`](windows/sysmon-config.xml) | `C:\Program Files\Sysmon\sysmon-config.xml` | Sysmon configuration — the high-signal process, network, and file baseline Logster analyzes. Based on the community [SwiftOnSecurity `sysmon-config`](https://github.com/SwiftOnSecurity/sysmon-config) (CC BY 4.0; attribution retained in the file header). |
| [`windows/winlogbeat.yml`](windows/winlogbeat.yml) | `C:\Program Files\Winlogbeat\winlogbeat.yml` | Winlogbeat shipper configuration for the **OVA appliance** — forwards the Sysmon channel to the App Node's Kafka listener on port 29092 (plaintext). |
| [`windows/winlogbeat-openshift.yml`](windows/winlogbeat-openshift.yml) | `C:\Program Files\Winlogbeat\winlogbeat.yml` | Winlogbeat shipper configuration for **OpenShift** deployments — ships to the Kafka bootstrap route on port 443 over TLS, with certificate validation disabled. |

## Using these files

Both endpoint installation guides walk through this in order; the short
version:

**Linux.** The sensor release package already ships this baseline, so in a
standard deployment you do not need to download anything from here — the
sensor filter is installed and active, and the auditd ruleset is staged at
`/usr/share/logster-ebpf-sensor/audit.rules` for you to review and apply.
Use this repository to review coverage, or to pull an updated baseline onto an
existing endpoint:

```bash
# auditd ruleset — dropped into rules.d and compiled by augenrules, so it
# coexists with any baseline you already run
sudo curl -fsSL -o /etc/audit/rules.d/logster.rules \
  https://raw.githubusercontent.com/eunomatix/logster-endpoint-configs/main/linux/auditd/audit.rules
sudo augenrules --load

# eBPF sensor filter
sudo curl -fsSL -o /etc/logster/ebpf-sensor/filter.json \
  https://raw.githubusercontent.com/eunomatix/logster-endpoint-configs/main/linux/ebpf-sensor/filter.json
sudo systemctl restart logster-ebpf-sensor
```

**Windows.** Download `sysmon-config.xml` plus the Winlogbeat configuration
that matches your deployment, set your Logster address in it, then install
Sysmon with the configuration and start the Winlogbeat service. Both
Winlogbeat files install to the same path — pick one:

| Your deployment | Use | Kafka target |
| --- | --- | --- |
| Two-node OVA appliance | `winlogbeat.yml` | App Node `:29092`, plaintext |
| OpenShift / Helm | `winlogbeat-openshift.yml` | Kafka bootstrap route `:443`, TLS with certificate validation off |

> [!IMPORTANT]
> Every shipper configuration contains a placeholder for your Logster
> address. On Linux, `logster-sensor-setup --brokers <host:port>` fills it in
> for you. On Windows, edit `output.kafka.hosts` by hand before starting the
> service.
>
> Do not mix the two Windows files up. TLS settings must match the listener:
> the appliance listener is plaintext, so `ssl.enabled: true` against it will
> fail to connect; the OpenShift routes are TLS-only, so a plaintext client
> will fail there.

## Tuning

Both collector configurations are safe to tune for your fleet — add a watched
path, exclude a noisy in-house process, widen or narrow coverage. Keep local
changes in your own configuration management so they survive package
upgrades, and contact Logster Support if you need coverage beyond this
baseline.

## Documentation

- [Logster documentation](https://docs.eunomatix.com/logster/)
- [Linux Event Collection Reference](https://docs.eunomatix.com/logster/technical-guides/appliance-deployment/linux-event-collection/)
  — what each Linux collector monitors
- [Connect Windows Endpoints](https://docs.eunomatix.com/logster/technical-guides/appliance-deployment/connect-windows-endpoints/)
