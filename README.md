# project
ci-cd-uebung

## GitHub Actions: OIDC-Anmeldung bei AWS

### Ablauf und konkrete Fundstellen

GitHub Actions benötigt hier keine dauerhaft hinterlegten AWS-Access-Keys: Die AWS-Jobs erlauben mit `permissions: id-token: write` das **Anfordern** eines kurzlebigen, von GitHub signierten OIDC-Tokens. Diese Einstellung allein meldet den Job noch nicht bei AWS an und gewährt keine AWS-Schreibrechte. Erst `aws-actions/configure-aws-credentials@v4` fordert das Token an und übergibt es zusammen mit `role-to-assume` an AWS STS (`AssumeRoleWithWebIdentity`). Wenn Provider und Trust Policy passen, liefert STS temporäre Zugangsdaten (Access Key ID, Secret Access Key, Session Token mit Ablaufzeit). Die Action stellt sie den folgenden Schritten des Jobs bereit.

| Datei im Repository | Job / genauer Schritt | Verwendete Rolle |
|---|---|---|
| [.github/workflows/aws-cicd.yml](.github/workflows/aws-cicd.yml) | `push_ecr` / **AWS-Anmeldung über OIDC** | Feste ARN `arn:aws:iam::945129430525:role/GitHubActions-CICD-Role`; danach ECR-Anmeldung und Image-Push |
| [.github/workflows/terraform.yml](.github/workflows/terraform.yml) | `plan` / **AWS-Anmeldung über OIDC** | `role-to-assume: ${{ vars.TERRAFORM_PLAN_ROLE_ARN }}` |
| [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) | `plan` / **AWS-Anmeldung mit Plan-Rolle** | `${{ vars.TERRAFORM_PLAN_ROLE_ARN }}` |
| [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) | `apply` / **AWS-Anmeldung mit Apply-Rolle** | `${{ vars.TERRAFORM_APPLY_ROLE_ARN }}`; Job nutzt `environment: terraform-apply` |

Alle vier AWS-Jobs setzen `id-token: write` auf Job-Ebene und verwenden die Action in Version `@v4` mit `aws-region: us-east-1`. **Terraform Validate** auf Pull Requests arbeitet ohne AWS-Anmeldung. Terraform Plan läuft in `terraform.yml` nur bei manuellem Start (`workflow_dispatch`) auf `refs/heads/main`. Der Plan-Job in `terraform-apply.yml` erlaubt ebenfalls nur `main`; der Apply-Job hängt über `needs: plan` davon ab. Die ECR-Pipeline startet bei Push auf `main` oder manuell; ihre Trust Policy begrenzt die Rollenübernahme auf `main`.

### AWS-Vertrauen und Berechtigungen unterscheiden

In [terraform/github-oidc.tf](terraform/github-oidc.tf) definiert `aws_iam_openid_connect_provider.github` den Aussteller `https://token.actions.githubusercontent.com` und die Audience `sts.amazonaws.com`. Die Trust Policies erlauben `sts:AssumeRoleWithWebIdentity` mit diesem Provider als `Federated`-Principal und prüfen beide Claims mit `StringEquals`:

| Terraform-Definition | Zielrolle | Erwarteter `sub` |
|---|---|---|
| `data.aws_iam_policy_document.github_oidc_trust` → `aws_iam_role.github_actions` in [github-oidc.tf](terraform/github-oidc.tf) | `GitHubActions-CICD-Role` | `repo:paololaspina@323260101/project@1434775201:ref:refs/heads/main` |
| `data.aws_iam_policy_document.terraform_plan_trust` → `aws_iam_role.terraform_plan` in [github-terraform-plan.tf](terraform/github-terraform-plan.tf) | `GitHubActions-Terraform-Plan-Role` | gleicher `main`-Subject |
| `data.aws_iam_policy_document.terraform_apply_trust` → `aws_iam_role.terraform_apply` in [github-terraform-apply.tf](terraform/github-terraform-apply.tf) | `GitHubActions-Terraform-Apply-Role` | `repo:paololaspina@323260101/project@1434775201:environment:terraform-apply` |

Bei allen drei Rollen muss `token.actions.githubusercontent.com:aud = sts.amazonaws.com` gelten. Die oben angegebenen Subjects sind die **exakten Werte dieses Repository-Codes**, einschließlich IDs; nicht durch ein allgemeines `repo:owner/repo:...`-Beispiel ersetzen. Ob GitHub aktuell genau diese Subjects ausstellt, muss am tatsächlichen Betrieb geprüft werden. Beim Environment-Subject steht die Umgebung anstelle der Branch-Referenz. Die Apply-Trust-Policy prüft daher selbst keinen Branch: Die Begrenzung auf `main` kommt aus dem Workflow und sollte zusätzlich in den Deployment-Branch-Regeln der Umgebung stehen.

**Trust Policy = Wer darf die Rolle übernehmen? IAM-Berechtigungspolicy = Was darf die übernommene Rolle tun? STS = Dienst, der nach erfolgreicher Prüfung die temporären Zugangsdaten ausstellt.** Konkret:

- `aws_iam_role_policy.github_ecr_push` in `terraform/github-oidc.tf` erlaubt ECR-Anmeldung und Zugriff auf das Projekt-Repository.
- `terraform_plan_readonly` und `terraform_plan_state` in `terraform/github-terraform-plan.tf` erlauben Ressourcenlesen und State-Lesen; für die State-Sperrdatei sind auch Schreib-/Löschrechte nötig.
- `terraform_apply_readonly` und `terraform_apply_state` in `terraform/github-terraform-apply.tf` ergänzen State-Schreibrechte. `aws_iam_role_policy.terraform_apply_write` in [terraform/github-terraform-apply-write.tf](terraform/github-terraform-apply-write.tf) erlaubt begrenzte Änderungen an Dashboard, Alarmen, ECR-Einstellungen und Security-Group-Regeln, keine IAM-Schreibrechte und kein `iam:PassRole`.

Die zusätzliche [github-oidc-trust.json](github-oidc-trust.json) enthält denselben `main`-Subject, aber eine andere feste AWS-Account-ID (`590183669588`) als der ECR-Workflow. Sie ist kein Nachweis für die aktuell in AWS aktive Trust Policy; maßgeblich sind Ziel-Account und tatsächlich bereitgestellte Rolle. [aws-lab-reset.sh](aws-lab-reset.sh) setzt und prüft die beiden Terraform-Rollen-ARNs als Repository-Variablen mit `gh variable set/get`; die ECR-Rollen-ARN im Workflow bleibt fest.

### In GitHub finden und im Kurs zeigen

1. **Code:** [Repository öffnen](https://github.com/paololaspina/project) → **Code** → Branch **main** → `.github` → `workflows` → gewünschte YAML-Datei. Im OIDC-Schritt `id-token: write`, `configure-aws-credentials@v4` und `role-to-assume` zeigen. Danach unter `terraform` die zugehörige Trust Policy und Berechtigungspolicy öffnen. Solange dieser Dokumentations-PR offen ist: dessen Branch wählen oder **Pull requests → PR → Files changed**.
2. **Rollen-ARNs:** **Settings → Secrets and variables → Actions → Variables → Repository variables** ([Direktlink](https://github.com/paololaspina/project/settings/variables/actions)). Dort `TERRAFORM_PLAN_ROLE_ARN` und `TERRAFORM_APPLY_ROLE_ARN` ansehen und mit dem aktuellen AWS-Account vergleichen. ARNs sind Rollenbezeichner, keine geheimen AWS-Schlüssel. Unter **Settings → Environments → terraform-apply** auch auf gleichnamige Environment-Variablen prüfen, die beim Apply-Job Vorrang haben können.
3. **Freigabeschutz:** **Settings → Environments → terraform-apply** ([Direktlink](https://github.com/paololaspina/project/settings/environments)) → **Deployment protection rules / Required reviewers** sowie **Deployment branches and tags** prüfen. `environment:` im Code allein garantiert keine eingerichtete Genehmigungspflicht.
4. **Lauf und Genehmigung:** **Actions → Terraform Apply → passenden Lauf öffnen**. Zuerst Summary des Jobs **Validate, Plan und Sicherheitsprüfung** lesen. Er erstellt und prüft den Plan und lädt ihn als `terraform-approved-plan` hoch. Bei aktiver Reviewer-Regel wartet **Terraform Apply (Genehmigung)**: berechtigte Person wählt **Review deployments → terraform-apply → Approve and deploy**. Erst danach startet der Job mit der Apply-Rolle, prüft die Plan-Prüfsumme und führt **Genehmigten Terraform-Plan anwenden** aus. Eine Vorführung der Doku erfordert keinen neuen Apply-Lauf.

### Nachweis in AWS CloudTrail und Erklärung für DQR 5

Für einen bereits ausgeführten Lauf: AWS-Konsole im passenden Account → **CloudTrail → Event history / Ereignisverlauf** → Zeitraum des GitHub-Laufs wählen → nach **Event name = AssumeRoleWithWebIdentity** filtern. Zuerst `us-east-1` prüfen, bei abweichendem STS-Endpunkt auch dessen Region. Im Ereignis-JSON `eventSource: sts.amazonaws.com`, `eventName`, Zeit, `requestParameters.roleArn`, Session sowie verfügbare Subject-/Audience-Angaben mit Workflow und Trust Policy vergleichen. Nur ein erfolgreicher Eintrag ohne Fehler belegt die erfolgreiche Rollenübernahme; ein Fehlerereignis belegt lediglich einen Versuch. **AWS Account ermitteln**, **AWS-Account prüfen** bzw. **AWS-Account abgleichen** zeigen im Workflow ergänzend die Nutzung von `aws sts get-caller-identity`, ersetzen aber nicht den CloudTrail-Nachweis. Keine Tokens oder Zugangsdaten für die Präsentation veröffentlichen.

**Kurzvortrag:** „Ich habe GitHub Actions über OIDC mit AWS verbunden. Der Job darf ein GitHub-Token anfordern. AWS prüft dessen Aussteller, Zielgruppe und Repository-Kontext gegen die Trust Policy. STS stellt dann zeitlich begrenzte Zugangsdaten aus. Getrennte IAM-Policies begrenzen Plan, Apply und ECR auf ihre Aufgaben. Für Apply kommt die GitHub-Umgebung mit ihrer eingerichteten Freigabe hinzu. Ich zeige die Kette am Workflow, an der Terraform-Rolle und an einem erfolgreichen CloudTrail-Ereignis.“

**Prüfstand dieser Dokumentation:** Repository-Code geprüft; aktuelle Variablenwerte, Environment-Reviewer/Branch-Regeln und AWS-/CloudTrail-Livezustand sind damit nicht bestätigt. Beim Abruf am 04.11.2026 meldete die Branch-Liste für `main` `protected: false`; die Repository-Ruleset-Liste war leer. Vor einem Merge den gewünschten Branch-Schutz und die PR-Prüfungen kontrollieren. Diese Dokumentationsänderung verändert keine Schutzregeln.

Grundlagen: [GitHub: OIDC mit AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [AWS STS: AssumeRoleWithWebIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html).

