# Tutorials App on AWS

A step-by-step tutorial that builds a small serverless app on AWS with Terraform: Cognito, a private VPC, RDS PostgreSQL, Lambda functions and API Gateway.

Each step has a Git tag (`step-01` to `step-07`) and a README in `docs/`.

| Step | Tag | Topic | README |
|---|---|---|---|
| 1 | `step-01` | Project structure | [docs/step-01-structure.md](docs/step-01-structure.md) |
| 2 | `step-02` | Cognito user pool | [docs/step-02-cognito.md](docs/step-02-cognito.md) |
| 3 | `step-03` | Network (VPC, subnets, security groups) | [docs/step-03-network.md](docs/step-03-network.md) |
| 4 | `step-04` | RDS PostgreSQL database | [docs/step-04-rds.md](docs/step-04-rds.md) |
| 5 | `step-05` | Lambda functions in the VPC | [docs/step-05-lambda.md](docs/step-05-lambda.md) |
| 6 | `step-06` | API Gateway with Cognito authorizer | [docs/step-06-api-gateway.md](docs/step-06-api-gateway.md) |
| 7 | `step-07` | Database schema and build pipeline | [docs/step-07-schema-build.md](docs/step-07-schema-build.md) |

To see the state after a step, run `git checkout step-0N`.

**Cost warning:** from step 4 on, the RDS database is billed per hour while it exists. Run `terraform destroy` at the end of every session.
