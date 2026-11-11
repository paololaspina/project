# project
ci-cd-uebung

## AWS-Lab nach einem Sandbox-Reset wiederherstellen

1. Nach dem Merge den lokalen Branch `main` aktualisieren, das AWS-Profil `lab` mit gültigen Sandbox-Zugangsdaten versorgen und `gh auth login` prüfen.
2. `./aws-lab-reset.sh --restore` ausführen. Das Skript erstellt bzw. verwendet den S3-State im ermittelten Konto und zeigt den Terraform-Plan zur Bestätigung an. Pläne mit Löschungen oder Ersetzungen werden abgelehnt. Der erste ECS-Bootstrap benötigt das Lab-Profil mit Rechten für ECS, IAM und gegebenenfalls die ECS-Service-Linked-Role.
3. Bei einem Kontowechsel die vorgeschlagenen Änderungen am Backend und an der ECR-Rollen-ARN über den angezeigten PR prüfen. Das Skript wartet auf die Checks und fragt separat nach der Merge-Freigabe. Die OIDC-Variablen für Terraform und ECS werden auf das neue Konto gesetzt.
4. Der Restore startet einen eigenen Actions-Lauf für den aktuellen `main`-Commit und wartet auf den Fargate-Smoke-Test. Anschließend installiert er dasselbe Commit-Image per SSM auf EC2 und prüft dort HTTP. Die Fargate-URL steht im Job **Deploy and smoke-test Fargate**, die EC2-URL in der Skriptausgabe.

Terraform registriert eine Task-Vorlage und erstellt den Dienst zunächst mit null Tasks. So funktioniert der Bootstrap auch mit leerem ECR. Nach einem Push auf `main` veröffentlicht GitHub Actions das nginx-Image unter dem vollständigen Commit-SHA oder verwendet das bereits vorhandene Tag. Der ECS-Deploy übernimmt den unveränderlichen Digest aus ECR, setzt den Dienst auf einen Task und prüft die ausgelieferte Seite gegen `index.html`. Spätere Terraform-Applies erhalten die laufende Revision und Task-Anzahl. Nach dem ersten Merge kann der automatisch ausgelöste Deploy bis zum ersten Restore fehlschlagen, da der ECS-Dienst und seine Rolle erst beim Restore entstehen.

EC2 und Fargate laufen parallel. `./aws-lab-reset.sh --deploy` aktualisiert weiterhin EC2 mit dem bereits veröffentlichten Image. Für eine erneute ECS-Bereitstellung den Workflow **AWS CI/CD Pipeline** auf `main` starten. Fargate nutzt das öffentliche Standardsubnetz in `us-east-1` und HTTP auf Port 80. Die öffentliche Task-IP kann sich bei einem neuen Task ändern. nginx-Logs stehen in `/ecs/cicd-webserver` für sieben Tage zur Verfügung.

Die getrennte ECS-Deploy-Rolle kann den Lab-Dienst aktualisieren und ausschließlich dessen Ausführungsrolle übergeben. Die Ausführungsrolle kann aus dem Lab-ECR lesen und in die nginx-Logstreams schreiben. Infrastruktur-Bootstrap bleibt beim bestätigten lokalen Restore. Der bestehende Terraform-Apply-Workflow nutzt weiterhin das geschützte Environment und seine eingeschränkte Änderungsliste.

Offline-Prüfung ohne AWS-Anmeldung

```bash
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform test
bash -n aws-lab-reset.sh
bash -n scripts/deploy-ecs.sh
python3 tests/test-aws-lab-reset.py
bash tests/test-ecs-deploy.sh
bash test.sh
```

## Grafana Cloud mit CloudWatch verbinden

1. `main` aktualisieren und `./aws-lab-reset.sh --restore` mit dem Profil `lab` ausführen. Der bestätigte Terraform-Plan erstellt auch die IAM-Rolle `GrafanaCloudWatchReadOnly`. Die Vertrauensdaten des Grafana-Stacks stehen in `terraform/grafana-cloudwatch.json`.
2. Die Rollen-ARN mit `AWS_PROFILE=lab terraform -chdir=terraform output -raw grafana_cloudwatch_role_arn` ausgeben.
3. In Grafana unter **Connections → Data sources → cloudwatch → Settings** bei **Grafana Assume Role** die ausgegebene ARN einfügen, **Default Region** auf `us-east-1` setzen und **Save & test** wählen.
4. In **Explore** mit der CloudWatch-Datenquelle `CPUUtilization` aus `AWS/EC2` bzw. `AWS/ECS` abfragen. Für nginx-Logs auf **Logs** umschalten und die Gruppe `/ecs/cicd-webserver` auswählen.

Bei einem Sandbox-Wechsel erstellt der Restore die Rolle im neuen Konto. Danach die neue ARN in derselben Grafana-Datenquelle speichern und erneut testen.

### Dashboard über GitHub Actions veröffentlichen

Das Dashboard in `grafana/aws-lab.json` zeigt EC2-CPU sowie CPU und Arbeitsspeicher des Fargate-Dienstes. Die UID `cicd-aws-lab` bleibt bei jedem Deployment gleich.

1. In Grafana unter **Administration → Users and access → Service accounts** ein Konto für GitHub Actions mit Dashboard-Schreib- und Leserechten anlegen. Für das Dashboard im Hauptordner funktioniert die Rolle **Editor**. Ein Service-Account-Token erzeugen und als Repository-Secret `GRAFANA_DASHBOARD_TOKEN` hinterlegen.
2. Die CloudWatch-Datenquelle in Grafana öffnen und ihre UID aus der URL nach `/connections/datasources/edit/` kopieren. Die UID in GitHub unter **Settings → Secrets and variables → Actions → Variables** als `GRAFANA_CLOUDWATCH_UID` speichern.
3. Unter **Actions → Grafana Dashboard → Run workflow** den Branch `main` wählen. Änderungen an der Dashboard-Datei oder dem Workflow auf `main` starten den Deploy automatisch. Der Job liest das Dashboard nach dem Upload zurück und verlinkt es in seiner Zusammenfassung.

Beim Sandbox-Reset die Rollen-ARN in der vorhandenen CloudWatch-Datenquelle aktualisieren. Dadurch bleibt ihre UID gültig und das Dashboard verwendet das neue AWS-Konto.

## GitHub Actions: OIDC-Anmeldung bei AWS

### Ablauf und konkrete Fundstellen

GitHub Actions benötigt hier keine dauerhaft hinterlegten AWS-Access-Keys: Die AWS-Jobs erlauben mit `permissions: id-token: write` das **Anfordern** eines kurzlebigen, von GitHub signierten OIDC-Tokens. Diese Einstellung allein meldet den Job noch nicht bei AWS an und gewährt keine AWS-Schreibrechte. Erst `aws-actions/configure-aws-credentials@v4` fordert das Token an und übergibt es zusammen mit `role-to-assume` an AWS STS (`AssumeRoleWithWebIdentity`). Wenn Provider und Trust Policy passen, liefert STS temporäre Zugangsdaten (Access Key ID, Secret Access Key, Session Token mit Ablaufzeit). Die Action stellt sie den folgenden Schritten des Jobs bereit.

| Datei im Repository | Job / genauer Schritt | Verwendete Rolle |
|---|---|---|
| [.github/workflows/aws-cicd.yml](.github/workflows/aws-cicd.yml) | `push_ecr` | Accountgebundene ARN der Rolle `GitHubActions-CICD-Role` |
| [.github/workflows/aws-cicd.yml](.github/workflows/aws-cicd.yml) | `deploy_ecs` | `${{ vars.ECS_DEPLOY_ROLE_ARN }}` |
| [.github/workflows/terraform.yml](.github/workflows/terraform.yml) | `plan` / **AWS-Anmeldung über OIDC** | `role-to-assume: ${{ vars.TERRAFORM_PLAN_ROLE_ARN }}` |
| [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) | `plan` / **AWS-Anmeldung mit Plan-Rolle** | `${{ vars.TERRAFORM_PLAN_ROLE_ARN }}` |
| [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) | `apply` / **AWS-Anmeldung mit Apply-Rolle** | `${{ vars.TERRAFORM_APPLY_ROLE_ARN }}`; Job nutzt `environment: terraform-apply` |

Alle fünf AWS-Jobs setzen `id-token: write` auf Job-Ebene und verwenden die Action in Version `@v4` mit `aws-region: us-east-1`. **Terraform Validate** auf Pull Requests arbeitet ohne AWS-Anmeldung. Terraform Plan läuft in `terraform.yml` nur bei manuellem Start (`workflow_dispatch`) auf `refs/heads/main`. Der Plan-Job in `terraform-apply.yml` erlaubt ebenfalls nur `main`; der Apply-Job hängt über `needs: plan` davon ab. Die ECR-Pipeline startet bei Push auf `main` oder manuell; ihre Trust Policy begrenzt die Rollenübernahme auf `main`.

### AWS-Vertrauen und Berechtigungen unterscheiden

In [terraform/github-oidc.tf](terraform/github-oidc.tf) definiert `aws_iam_openid_connect_provider.github` den Aussteller `https://token.actions.githubusercontent.com` und die Audience `sts.amazonaws.com`. Die Trust Policies erlauben `sts:AssumeRoleWithWebIdentity` mit diesem Provider als `Federated`-Principal und prüfen beide Claims mit `StringEquals`:

| Terraform-Definition | Zielrolle | Erwarteter `sub` |
|---|---|---|
| `data.aws_iam_policy_document.github_oidc_trust` → `aws_iam_role.github_actions` in [github-oidc.tf](terraform/github-oidc.tf) | `GitHubActions-CICD-Role` | `repo:paololaspina@323260101/project@1434775201:ref:refs/heads/main` |
| `data.aws_iam_policy_document.github_oidc_trust` → `aws_iam_role.github_ecs_deploy` in [github-ecs-deploy.tf](terraform/github-ecs-deploy.tf) | `GitHubActions-ECS-Deploy-Role` | gleicher `main`-Subject |
| `data.aws_iam_policy_document.terraform_plan_trust` → `aws_iam_role.terraform_plan` in [github-terraform-plan.tf](terraform/github-terraform-plan.tf) | `GitHubActions-Terraform-Plan-Role` | gleicher `main`-Subject |
| `data.aws_iam_policy_document.terraform_apply_trust` → `aws_iam_role.terraform_apply` in [github-terraform-apply.tf](terraform/github-terraform-apply.tf) | `GitHubActions-Terraform-Apply-Role` | `repo:paololaspina@323260101/project@1434775201:environment:terraform-apply` |

Bei allen vier Rollen muss `token.actions.githubusercontent.com:aud = sts.amazonaws.com` gelten. Die oben angegebenen Subjects sind die **exakten Werte dieses Repository-Codes**, einschließlich IDs; nicht durch ein allgemeines `repo:owner/repo:...`-Beispiel ersetzen. Ob GitHub aktuell genau diese Subjects ausstellt, muss am tatsächlichen Betrieb geprüft werden. Beim Environment-Subject steht die Umgebung anstelle der Branch-Referenz. Die Apply-Trust-Policy prüft daher selbst keinen Branch: Die Begrenzung auf `main` kommt aus dem Workflow und sollte zusätzlich in den Deployment-Branch-Regeln der Umgebung stehen.

**Trust Policy = Wer darf die Rolle übernehmen? IAM-Berechtigungspolicy = Was darf die übernommene Rolle tun? STS = Dienst, der nach erfolgreicher Prüfung die temporären Zugangsdaten ausstellt.** Konkret:

- `aws_iam_role_policy.github_ecr_push` in `terraform/github-oidc.tf` erlaubt ECR-Anmeldung und Zugriff auf das Projekt-Repository.
- `terraform_plan_readonly` und `terraform_plan_state` in `terraform/github-terraform-plan.tf` erlauben Ressourcenlesen und State-Lesen; für die State-Sperrdatei sind auch Schreib-/Löschrechte nötig.
- `terraform_apply_readonly` und `terraform_apply_state` in `terraform/github-terraform-apply.tf` ergänzen State-Schreibrechte. `aws_iam_role_policy.terraform_apply_write` in [terraform/github-terraform-apply-write.tf](terraform/github-terraform-apply-write.tf) erlaubt begrenzte Änderungen an Dashboard, Alarmen, ECR-Einstellungen und Security-Group-Regeln, keine IAM-Schreibrechte und kein `iam:PassRole`.

Die zusätzliche [github-oidc-trust.json](github-oidc-trust.json) enthält denselben `main`-Subject, aber eine andere feste AWS-Account-ID (`590183669588`) als der ECR-Workflow. Sie ist kein Nachweis für die aktuell in AWS aktive Trust Policy; maßgeblich sind Ziel-Account und tatsächlich bereitgestellte Rolle. [aws-lab-reset.sh](aws-lab-reset.sh) setzt und prüft die Terraform- und ECS-Deploy-Rollen-ARNs als Repository-Variablen mit `gh variable set/get`; die ECR-Rollen-ARN im Workflow bleibt fest.

### In GitHub finden und im Kurs zeigen

1. **Code:** [Repository öffnen](https://github.com/paololaspina/project) → **Code** → Branch **main** → `.github` → `workflows` → gewünschte YAML-Datei. Im OIDC-Schritt `id-token: write`, `configure-aws-credentials@v4` und `role-to-assume` zeigen. Danach unter `terraform` die zugehörige Trust Policy und Berechtigungspolicy öffnen.
2. **Rollen-ARNs:** **Settings → Secrets and variables → Actions → Variables → Repository variables** ([Direktlink](https://github.com/paololaspina/project/settings/variables/actions)). Dort `TERRAFORM_PLAN_ROLE_ARN` und `TERRAFORM_APPLY_ROLE_ARN` ansehen und mit dem aktuellen AWS-Account vergleichen. ARNs sind Rollenbezeichner, keine geheimen AWS-Schlüssel. Unter **Settings → Environments → terraform-apply** auch auf gleichnamige Environment-Variablen prüfen, die beim Apply-Job Vorrang haben können.
3. **Freigabeschutz:** **Settings → Environments → terraform-apply** ([Direktlink](https://github.com/paololaspina/project/settings/environments)) → **Deployment protection rules / Required reviewers** sowie **Deployment branches and tags** prüfen. `environment:` im Code allein garantiert keine eingerichtete Genehmigungspflicht.
4. **Lauf und Genehmigung:** **Actions → Terraform Apply → passenden Lauf öffnen**. Zuerst Summary des Jobs **Validate, Plan und Sicherheitsprüfung** lesen. Er erstellt und prüft den Plan und lädt ihn als `terraform-approved-plan` hoch. Bei aktiver Reviewer-Regel wartet **Terraform Apply (Genehmigung)**: berechtigte Person wählt **Review deployments → terraform-apply → Approve and deploy**. Erst danach startet der Job mit der Apply-Rolle, prüft die Plan-Prüfsumme und führt **Genehmigten Terraform-Plan anwenden** aus. Eine Vorführung der Doku erfordert keinen neuen Apply-Lauf.

### Nachweis in AWS CloudTrail und Erklärung für DQR 5

Für einen bereits ausgeführten Lauf: AWS-Konsole im passenden Account → **CloudTrail → Event history / Ereignisverlauf** → Zeitraum des GitHub-Laufs wählen → nach **Event name = AssumeRoleWithWebIdentity** filtern. Zuerst `us-east-1` prüfen, bei abweichendem STS-Endpunkt auch dessen Region. Im Ereignis-JSON `eventSource: sts.amazonaws.com`, `eventName`, Zeit, `requestParameters.roleArn`, Session sowie verfügbare Subject-/Audience-Angaben mit Workflow und Trust Policy vergleichen. Nur ein erfolgreicher Eintrag ohne Fehler belegt die erfolgreiche Rollenübernahme; ein Fehlerereignis belegt lediglich einen Versuch. **AWS Account ermitteln**, **AWS-Account prüfen** bzw. **AWS-Account abgleichen** zeigen im Workflow ergänzend die Nutzung von `aws sts get-caller-identity`, ersetzen aber nicht den CloudTrail-Nachweis. Keine Tokens oder Zugangsdaten für die Präsentation veröffentlichen.

**Kurzvortrag:** „Ich habe GitHub Actions über OIDC mit AWS verbunden. Der Job darf ein GitHub-Token anfordern. AWS prüft dessen Aussteller, Zielgruppe und Repository-Kontext gegen die Trust Policy. STS stellt dann zeitlich begrenzte Zugangsdaten aus. Getrennte IAM-Policies begrenzen Plan, Apply und ECR auf ihre Aufgaben. Für Apply kommt die GitHub-Umgebung mit ihrer eingerichteten Freigabe hinzu. Ich zeige die Kette am Workflow, an der Terraform-Rolle und an einem erfolgreichen CloudTrail-Ereignis.“

**Prüfstand dieser Dokumentation:** Repository-Code geprüft; GitHub-Einstellungen zusätzlich live gelesen: Repository-Variablen `TERRAFORM_APPLY_ROLE_ARN = arn:aws:iam::945129430525:role/GitHubActions-Terraform-Apply-Role`, `TERRAFORM_PLAN_ROLE_ARN = arn:aws:iam::945129430525:role/GitHubActions-Terraform-Plan-Role`. Die Umgebung `terraform-apply` verlangt Reviewer `paololaspina`, erlaubt ausschließlich Branch `main` und enthält keine Environment-Variablen; Selbstfreigabe ist erlaubt (`prevent_self_review: false`). AWS-/CloudTrail-Livezustand und tatsächliche Token-Claims sind nicht bestätigt. Am 04.11.2026 wurde das aktive Ruleset [main-protection](https://github.com/paololaspina/project/rules/26559534) für `main` bestätigt: Pull Request erforderlich, `Terraform Validate` als Pflichtprüfung, aktueller Branch-Stand und gelöste Review-Diskussionen erforderlich; Löschen und Force-Push gesperrt. Keine Bypass-Ausnahmen und keine verpflichtende zweite Person für die Freigabe. Branch-Schutz kontrolliert die Übernahme von Code, die Environment-Freigabe kontrolliert Terraform Apply.

Grundlagen: [GitHub: OIDC mit AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [AWS STS: AssumeRoleWithWebIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html).

