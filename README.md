# Salesforce Loan Product REST + Config MCP

This Salesforce DX project contains the loan-product configuration REST API,
four MCP actions, the `ConfigMCP` server definition, and the External Client
Application (ECA) used by both MCP and REST clients.

## What is included

| Capability | Metadata |
| --- | --- |
| Read REST endpoints | `LoanProductConfigService` at `/services/apexrest/v1/loanproductconfig/*` |
| Upload/deploy endpoint | `POST /services/apexrest/v1/loanproductconfig/deploy` in the same REST class |
| MCP actions | `ListProductsAction`, `GetProductAction`, `DiffRecordAction`, `DeployProductAction` |
| Hosted MCP server | `McpServerDefinition:ConfigMCP` |
| OAuth client | `ExternalClientApplication:Symphonix_MCP` and its OAuth metadata |

The read and upload operations are implemented by the same REST service. The
four invocable Apex classes are small MCP-facing wrappers around that service.
There is no separate Connected App: the ECA requests `Api`, `RefreshToken`, and
`MCP` OAuth scopes, so one access token can authorize Apex REST and ConfigMCP.

## Namespace behavior

The service does **not** hardcode the lending package namespace. It discovers
`Loan_Product__c` and its fields through Salesforce Schema describe data, using
bare-name/suffix matching. The same Apex therefore supports:

- Unmanaged development orgs: `Loan_Product__c`
- Official Loan Servicing package: `loan__Loan_Product__c`
- Internal QA/development packages: for example, `w22loan__Loan_Product__c`

`win22` in `sfdx-project.json` is different: it is the namespace of this Config
Manager 2GP package. Consequently, after installing the package, its own action
classes are named `win22__ListProductsAction`, `win22__GetProductAction`, and so
on. Those MCP references do not hardcode the Loan Servicing namespace.

## Repository layout

- `force-app` is the managed 2GP core: Apex, tests, ECA, and publisher-controlled
  OAuth settings.
- `post-install` is subscriber metadata: `ConfigMCP` and configurable ECA
  policies.
- `manifest/package-core.xml` deploys only the managed-package core metadata.
- `manifest/package-post-install.xml` deploys the subscriber-side metadata.
- `manifest/package.xml` is the combined source-deployment manifest.

Salesforce does not support `McpServerDefinition` in an ISV managed package.
For that reason the repository is one release bundle, but installation has two
phases: install the released 2GP, then deploy the post-install manifest.

## Validate in a connected org

Use an authenticated org alias in place of `<alias>`:

```bash
sf project deploy start \
  --manifest manifest/package.xml \
  --target-org <alias> \
  --dry-run \
  --test-level RunSpecifiedTests \
  --tests LoanProductConfigServiceTest \
  --tests LoanProductConfigActionsTest \
  --tests LoanProductConfigInternalsTest \
  --wait 30
```

The current suite has 19 tests. It passed 19/19 both in a dependency-free
validation org and in the connected `Dec25RC` org, whose Loan package namespace
is `w22loan`. `LoanProductConfigService` reached 76.67% and 79.97% coverage,
respectively; every MCP wrapper reached at least 95%.

## Build and release the 2GP

The existing managed-package lineage is `MyConnectedAppPackage` in the `win22`
namespace. The historical package name is retained because the Package2 lineage
already exists; the package contains an ECA, not a legacy Connected App. Version
`1.2.0.NEXT` descends from released version `1.1.0.1`. No lending-package
dependency is declared because the Apex uses only runtime Schema resolution.
Install the appropriate lending products in each subscriber org before calling
the REST endpoints or MCP tools.

```bash
sf package version create \
  --package MyConnectedAppPackage \
  --target-dev-hub <dev-hub-alias> \
  --definition-file config/project-scratch-def.json \
  --installation-key-bypass \
  --code-coverage \
  --wait 30

sf package version promote \
  --package <04t-package-version-id> \
  --target-dev-hub <dev-hub-alias> \
  --no-prompt
```

Package version creation always produces a beta first. Promotion changes that
validated version to Released, which is the installable non-beta 2GP requested
for production use.

The current released version is **1.2.0.2**:

- Subscriber package version ID: `04tg5000000Emj7AAC`
- Package coverage: 75% (Salesforce coverage check passed)
- Install URL: `https://login.salesforce.com/packaging/installPackage.apexp?p0=04tg5000000Emj7AAC`

The released package was installed successfully in the connected `Clcommon`
org, which does not contain `Loan_Product__c`. A validation deployment of the
three configurable ECA policy components and `McpServerDefinition:ConfigMCP`
also succeeded there with no component failures.

## Install and configure ConfigMCP

Install the released version, then deploy the subscriber metadata:

```bash
sf package install \
  --package 04tg5000000Emj7AAC \
  --target-org <alias> \
  --wait 30 \
  --no-prompt

sf project deploy start \
  --manifest manifest/package-post-install.xml \
  --target-org <alias> \
  --wait 30
```

The authenticated user needs API access, access to Salesforce MCP servers,
Apex class access to the service/actions, object and field access to the Loan
Servicing model, and record access required by the classes' `with sharing`
behavior.

## MCP smoke test

The existing shell harness reads credentials from environment variables and
does not store access tokens in source:

```bash
export SF_MCP_ACCESS_TOKEN='<short-lived access token>'
export SF_MCP_URL='https://api.salesforce.com/platform/mcp/v1/sandbox/custom/ConfigMCP'
export SF_MCP_PRODUCT_ID='<optional Loan Product Id>'
./Shell/mcp-test.sh
```

Review the ECA callback URLs and configurable policies for each subscriber
environment before enabling non-admin users.
