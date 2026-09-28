# Salesforce Loan Product REST + MCP Bundle

This Salesforce DX project is the canonical deployment bundle for the loan
product configuration REST API, Salesforce-hosted MCP tools, and the External
Client App used by MCP clients.

## Included metadata

| Capability | Metadata |
| --- | --- |
| REST API | `LoanProductConfigService` at `/services/apexrest/v1/loanproductconfig/*` |
| MCP tools | `ListProductsAction`, `GetProductAction`, `DiffRecordAction`, `DeployProductAction` |
| Hosted MCP server | `McpServerDefinition:ConfigMCP` |
| OAuth client | `ExternalClientApplication:Symphonix_MCP` and its OAuth settings/policies |

The exact deployment scope is declared in [`manifest/package.xml`](manifest/package.xml).

## Validate and deploy

Use an authenticated org alias in place of `<alias>`.

```bash
sf project deploy start \
  --manifest manifest/package.xml \
  --target-org <alias> \
  --dry-run \
  --wait 30

sf project deploy start \
  --manifest manifest/package.xml \
  --target-org <alias> \
  --wait 30
```

The ECA and MCP metadata was retrieved from the `Dec25RC` org at API version
66.0. Cross-references contain the `w22loan` namespace and are intended for the
same package namespace.

## Post-deployment access

The authenticated user needs:

- API Enabled and access to Salesforce MCP servers.
- Apex class access to all five classes in the manifest.
- Object and field permissions for the loan product objects touched by the
  service.
- Sharing access to the records, because the classes run `with sharing`.

No deployable custom permission set granting this access existed in the source
org; the current access came from the System Administrator profile. Create a
least-privilege permission set before rolling this out to non-admin users.

## MCP smoke test

The test harness reads credentials from environment variables and never stores
tokens in source.

```bash
export SF_MCP_ACCESS_TOKEN='<short-lived access token>'
export SF_MCP_URL='https://api.salesforce.com/platform/mcp/v1/sandbox/custom/ConfigMCP'
export SF_MCP_PRODUCT_ID='<optional Loan Product Id>'
./Shell/mcp-test.sh
```

## Packaging and security notes

- Salesforce Hosted MCP uses an External Client App; Connected Apps are not
  supported for MCP authentication.
- `McpServerDefinition` can be moved between orgs with Metadata API, but
  Salesforce currently does not allow it inside an ISV managed package. For an
  ISV package, package the Apex/ECA metadata and deploy or configure the MCP
  server separately in the subscriber org.
- The five Apex classes currently have 0% recorded coverage in `Dec25RC` and no
  matching test classes in this repository. Add tests before a production or
  managed-package release.
- The retrieved ECA policy currently allows self-authorization, bypasses IP
  restrictions, uses a 365-day refresh-token lifetime, and has refresh-token
  rotation disabled. Review these settings for production.
- The callback list includes localhost and placeholder portal URLs. Replace the
  placeholders with the exact HTTPS callbacks used by your MCP clients.
