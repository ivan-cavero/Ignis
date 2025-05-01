🔥 Ignis Project Documentation
Overview
Ignis is a scalable and secure deployment and management platform designed to simplify the orchestration of various services on a VPS running Debian 12. It enables users to deploy game servers (e.g., Minecraft), frontend/backend applications, databases, and more, without requiring knowledge of Docker or Kubernetes. The platform also provides administrative and user dashboards for monitoring and management.

Project Vision
User-Friendly Deployment: Allow users to deploy services effortlessly, choosing from predefined templates or custom configurations.

Scalability: Utilize containerization and orchestration tools to handle multiple deployments efficiently.

Security: Implement best practices to secure the VPS and deployed services.

Flexibility: Support custom domains and subdomains for deployed services.

Technologies Used
Backend
Hono: A lightweight and fast web framework for building APIs, compatible with various runtimes like Node.js, Deno, and Cloudflare Workers. hono.dev

Node.js: JavaScript runtime environment for executing backend code.

Docker: Containerization platform to package applications and their dependencies.

Kubernetes: Orchestration system for automating deployment, scaling, and management of containerized applications.

Frontend
Vue 3: Progressive JavaScript framework for building user interfaces.

Vite: Build tool that provides a fast development environment.

Tailwind CSS: Utility-first CSS framework for designing responsive interfaces.

DevOps & Automation
Ansible: Automation tool for configuring systems and deploying applications.

Nginx: Web server and reverse proxy for handling HTTP requests and managing subdomains.

Certbot: Tool for obtaining SSL certificates from Let's Encrypt.

Architecture Overview
User Interface: Built with Vue 3, providing dashboards for both administrators and users.

API Server: Developed using Hono, handling requests related to deployments, user management, and service monitoring.

Container Management: Docker and Kubernetes manage the lifecycle of deployed services.

Reverse Proxy: Nginx routes incoming traffic to the appropriate services based on subdomains or paths.

Automation Scripts: Bash and Ansible scripts automate the setup and configuration of the VPS and services.

Domain and Subdomain Management
Primary Domain: vps.ivancavero.com serves as the main entry point, hosting the landing page and administrative dashboard.

Dynamic Subdomains: Users can deploy services accessible via subdomains like project-<unique-id>.ivancavero.com.

Custom Domains: Users have the option to link their own domains to deployed services.

Security Measures
SSH Configuration: Disabling root login and changing the default SSH port.

Firewall: Using UFW to restrict incoming and outgoing traffic.

Fail2Ban: Protecting against brute-force attacks.

SSL Certificates: Securing HTTP traffic with HTTPS using Certbot.

Future Enhancements
Monitoring Tools: Integrate Prometheus and Grafana for real-time monitoring and alerting.

Resource Management: Implement quotas and limits to manage resource usage per deployment.

Template Library: Provide a collection of deployment templates for common applications.

Mobile Support: Ensure the user interface is responsive and accessible on mobile devices.