# Azure Governed VM Deployment — Terraform, RBAC & Policy

Provisioning an Azure Linux VM with Terraform, wrapped in the guardrails you'd actually
see in an enterprise or regulated environment: **tag-based cost governance via Azure Policy**,
**least-privilege access via a custom RBAC role**, and a **resource-group budget** for spend
control. Built as part of my AZ-104 preparation and Azure engineering portfolio.

---

## What this project demonstrates

- **Infrastructure as Code** — full environment defined in Terraform (`azurerm` provider), deployed and destroyed repeatably from a single `terraform apply`.
- **Azure networking** — VNet, subnet, and network interface wired together with resource dependencies.
- **Governance with Azure Policy** — assigned the built-in *Require a tag on resources* policy at the resource-group scope, parameterized to enforce a `CostCenter` tag. Non-compliant resources are blocked at creation time, not flagged after the fact.
- **Least-privilege RBAC** — authored a **custom role definition** scoped to only two actions (`read` and `restart`) on the VM, instead of granting a broad built-in role like Contributor, then assigned it to a principal.
- **Cost management** — attached a consumption budget to the resource group.
- **Secure Linux access** — SSH key–based authentication only; password auth disabled on the VM.

---

## Architecture

```
Resource Group (rg-az104lab)
│
├── Azure Policy Assignment ──── enforces "CostCenter" tag on all resources in the RG
├── Consumption Budget ───────── spend guardrail on the RG
│
├── Virtual Network (vnet-az104lab)
│   └── Subnet (snet-az104lab)
│       └── Network Interface (nic-az104lab)
│           └── Linux VM (vm-az104lab)  ──  Ubuntu 22.04 LTS, SSH-key auth, tagged
│
└── Custom RBAC Role ("VM Restart Operator")
    ├── Actions: virtualMachines/read, virtualMachines/restart/action
    └── Role Assignment ──────── scoped to the VM only
```

---

## Resources deployed

| Resource | Terraform address | Purpose |
|---|---|---|
| Resource group | `azurerm_resource_group.rg` | Container / governance scope |
| Virtual network | `azurerm_virtual_network.vnet` | Network boundary |
| Subnet | `azurerm_subnet.subnet` | VM placement |
| Network interface | `azurerm_network_interface.nic` | VM connectivity |
| Linux VM | `azurerm_linux_virtual_machine.vm` | Ubuntu 22.04 LTS, `Standard_E2s_v3` |
| Policy definition (data) | `data.azurerm_policy_definition.require_tag` | Looks up built-in tag policy |
| Policy assignment | `azurerm_resource_group_policy_assignment.tags` | Enforces `CostCenter` tag |
| Custom role definition | `azurerm_role_definition.vm_restart` | Least-privilege read/restart role |
| Role assignment | `azurerm_role_assignment.vm_restart` | Grants the custom role |
| Consumption budget | `azurerm_consumption_budget_resource_group.budget` | RG spend control |

---

## Troubleshooting log

I deployed this into a real subscription with real quota limits rather than a sandbox, so the
first `apply` didn't just work. Diagnosing the failures was the most useful part of the lab —
each error was a different Azure control plane response with a different root cause. Documented
here because reading these errors correctly is a core operational skill.

### 1. `file()` couldn't find the SSH public key — `Invalid function argument`

The config referenced the key as `file("~/.ssh/id_rsa.pub")`. Terraform's `file()` function
does **not** expand `~` — that's a shell convention, not something Terraform understands. It was
looking for a directory literally named `~`.

**Fix:** wrapped the path in `pathexpand()` so `~` resolves to the real home directory at runtime,
keeping the config portable across machines:

```hcl
public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
```

### 2. Key still not found — file genuinely didn't exist

Once the path resolved correctly, the error pointed at `C:\Users\ROMY\.ssh\id_rsa.pub` — proving
the path was now right, but no keypair existed there yet. `file()` reads local files at plan time;
it does not generate them.

**Fix:** generated the keypair before running Terraform:

```powershell
ssh-keygen -t rsa -b 4096 -f C:\Users\ROMY\.ssh\id_rsa
```

### 3. `403 Forbidden — RequestDisallowedByPolicy`

The NIC was blocked at creation by the `require-costcenter` policy assignment because it had no
`CostCenter` tag. Azure Policy enforces at the control plane *before* the resource is created —
this is the governance working as intended.

**Fix:** added the required tag to every resource in the RG (centralized as a local to stay DRY):

```hcl
tags = {
  CostCenter = "az104lab"
}
```

### 4. `400 Bad Request — InvalidParameter` (invalid VM size string)

Deployment rejected `Standard_D1s` — not a real SKU name — and later `Standard DSv2`, which had a
stray space. Every valid Azure size string uses underscores (`Standard_D2s_v3`), no spaces.

### 5. `409 Conflict — OperationNotAllowed` (zero quota)

`Standard_D4a_v4` is a valid SKU, but it maps to the **DAv4 family**, which my subscription had a
quota limit of **0** for. Valid SKU, no approved capacity.

### 6. `409 Conflict — SkuNotAvailable` (regional capacity)

`Standard_B2s` had quota available but returned a **capacity restriction** in `eastus` — Azure
simply had no B2s capacity to hand out in that region at that moment.

**Diagnosis / final fix:** I stopped guessing and cross-referenced quota against valid SKUs:

```powershell
az vm list-usage --location eastus --output table   # which families have quota > 0
az vm list-skus  --location eastus --output table   # which SKUs are valid in-region
```

The `ESv3` family already showed `2/10` vCPUs in use — proving real, available headroom. Switched
the VM to `Standard_E2s_v3` and the deployment completed.

**Takeaway:** a VM size has to clear *three* independent checks — valid SKU string, non-zero
family quota, and available regional capacity. A 400 means the string is wrong; a 409 means the
string is fine but capacity or quota isn't there. Checking `list-usage` + `list-skus` up front
beats trial and error.

---

## How to run

**Prerequisites:** Terraform, Azure CLI (logged in via `az login`), and an SSH keypair at
`~/.ssh/id_rsa`.

```powershell
terraform init      # download the azurerm provider
terraform fmt       # format check
terraform validate  # syntax / config validation
terraform plan      # preview
terraform apply     # deploy
terraform destroy   # tear down (avoid idle spend)
```

> `terraform.tfvars` is not committed. Copy `terraform.tfvars.example` and set your own values.

---

## Outputs

```
custom_role_name    = "VM Restart Operator (az104lab)"
resource_group_name = "rg-az104lab"
vm_name             = "vm-az104lab"
vm_id               = "/subscriptions/.../virtualMachines/vm-az104lab"
```

---

## Skills mapped to AZ-104

| AZ-104 domain | Demonstrated by |
|---|---|
| Manage identities and governance | Custom RBAC role, role assignment, Azure Policy, resource tagging, budgets |
| Deploy and manage compute | Linux VM provisioning, SKU selection, quota/capacity troubleshooting |
| Configure and manage virtual networking | VNet, subnet, NIC |
| Monitor and maintain resources | Consumption budget for cost control |
| (Cross-cutting) Automation | Entire environment as Terraform IaC |
