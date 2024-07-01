# ReynardSec Test Kubernetes Cluster installer

This repository contains a script for setting up a test instance of a Kubernetes cluster using Multipass. This setup is intended for those who wish to experiment with Kubernetes in a sandbox environment on their local machines.

For detailed information on securing your Kubernetes cluster, refer to the Kubernetes Security Guide available at [Kubernetes Security Guide](https://reynardsec.com/en/kubernetes-security-guide/). This guide provides comprehensive coverage on best practices for securing Kubernetes deployments.

## How to Use the Script
To use the script, follow these steps:
1. Ensure you have Multipass installed on your machine. If not, you can download it from [Multipass official website](https://multipass.run/).
2. Ensure you have kubectl installed on your machine. If not, you can find installation instruction in [offical documentation](https://kubernetes.io/docs/tasks/tools/).
3. Clone this repository to your local machine.
4. Navigate to the cloned repository in your terminal (`cd kubernetes-security-guide`)
5. Run the script using the command `./bootstrap-kubernetes.sh` (or `.\bootstrap-kubernetes.ps1` for Windows).

### Cleaning up

If you would like to revert changes made by the script (delete the created virtual machines), you can use the `cleanup.sh` (or `cleanup.ps1`) script.


## Contributing
If you have suggestions for improving the setup script or if you encounter any issues, please feel free to open an issue or submit a pull request.
