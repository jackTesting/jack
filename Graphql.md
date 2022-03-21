title: Onboarding Process

## Project Phases

The process of onboarding a Product team’s applications involves four phases:

1. Discovery – Initial meeting between Edge and the Product team to discuss goals
2. Planning – Technical deep-dive, analysis and design
3. Implementation – Development to deploy the applications using Edge
4. Validation – Evaluation and User Acceptance Testing

![image](https://user-images.githubusercontent.com/66746755/112484073-ff4b7480-8d4f-11eb-8f73-276d785097b6.png){: .zoom}

!!! todo
    Need to point users to names or slack channel to get started with this

### Application Deployment Models

!!! warning
    This section is out of date. At this time {{ project.name }} will **not** support non-containerized applications. In store VM workloads will be handled through traditional SDS measures.

NCR Edge automates the deployment of containerized applications and virtualized applications to clusters:

- Containerized applications are deployed via Helm charts and Docker images.
- Virtualized applications are deployed via Ansible Playbooks and artifacts.

![image](https://user-images.githubusercontent.com/66746755/112187537-8fff4480-8bd8-11eb-9582-79b7ab30a47f.png){: .zoom}

## Types of Onboarding

### Product

NCR products that are to run on top of the {{ project.name }} platform, either in the store or in cloud, must at this time be packaged as a [Helm chart](https://helm.sh/).

Additional info about how to add Helm charts to {{ project.name }} can be found [here](helm-charts).

### Platform

After the initial discovery phase it may be determined that some services will need to be integrated directly into {{ project.name }}. These services are what we call "first class" services meaning they will be deployed to clusters in a same way the {{ project.name }} management services are.

These NCR services will go to entitled customers that are supposed to consume it, not all customers. Being first class means that they will be automatically deployed to all clusters connected to the {{ project.name }} control plane without any additional actions by the user. There could be additional configuration steps but that is dependent on the services themselves.

More information about this type of onboarding can be found [here](./platform).

## Testing

More to come here.

## Additional Help

While this documentation is supposed to be all inclusive, it is a work in progress that will be ever growing. If there is anything that needs clarity or you have additional questions, please contact us in our slack channel {{ slackchannel("onboarding") }}.