# docker-yocto-env README

# Docker Yocto Environment

This project provides a containerized environment for building and managing Yocto projects using Docker. It is designed to simplify the setup and usage of the Yocto build system by leveraging Docker's capabilities.

## Project Structure

The project is organized into several directories and files:

- **core/**: Contains core scripts for environment setup and management.
  - `env_core.sh`: Main environment setup script.
  - `plugin_loader.sh`: Dynamically loads plugins from the `plugins` directory.
  - `common.sh`: Contains common utility functions.
  - `config.sh`: Manages configuration settings.

- **plugins/**: Contains plugin scripts that extend the functionality of the core environment.
  - `poky.sh`: Functions related to the Poky build system.
  - `info.sh`: Functions to retrieve and display information about available machines, images, and distributions.
  - `cleanup.sh`: Functions for cleaning up the work directory and analyzing Docker volumes.
  - `filebrowser.sh`: Manages the file browser service.
  - `rpm-host.sh`: Handles RPM repository hosting functionalities.
  - `nfs-server.sh`: Manages NFS server functionalities.

- **lib/**: Contains utility scripts for Docker and volume management.
  - `docker_utils.sh`: Utility functions for Docker operations.
  - `volume_utils.sh`: Functions for managing Docker volumes.
  - `compose_utils.sh`: Utility functions for handling Docker Compose operations.

- **env/**: Directory for environment-specific configurations or scripts.

- `docker-compose.template.yml`: Template for Docker Compose configuration.

- `Dockerfile_22.04`: Instructions for building the Docker image.

## Setup Instructions

1. **Clone the Repository**: 
   ```bash
   git clone <repository-url>
   cd docker-yocto-env
   ```

2. **Build the Docker Image**:
   ```bash
   docker build -t yocto-env -f Dockerfile_22.04 .
   ```

3. **Source the Environment**:
   To set up the environment, source the `env_core.sh` script:
   ```bash
   source core/env_core.sh
   ```

4. **Load Plugins**:
   The environment will automatically load available plugins from the `plugins` directory.

## Usage Guidelines

After sourcing the environment, you can use the following commands:

- **Poky Commands**: Interact with the Poky build system.
- **Info Commands**: Retrieve information about available machines, images, and distributions.
- **Cleanup Commands**: Clean up the work directory and analyze Docker volumes.
- **File Browser Commands**: Manage the file browser service.
- **RPM Host Commands**: Handle RPM repository hosting functionalities.
- **NFS Server Commands**: Manage NFS server functionalities.

## Available Commands

For a list of available commands and their usage, refer to the documentation within each plugin script or the core environment script.

## Contributing

Contributions are welcome! Please submit a pull request or open an issue for any enhancements or bug fixes.

## License

This project is licensed under the MIT License. See the LICENSE file for more details.