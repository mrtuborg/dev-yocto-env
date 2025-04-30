## 1. Add as a submodule to your YOCTO project
user/yocto_project% git submodule add git@server:docker-yocto-env

## 2. Create symbolik link, i.e:
user/yocto_project% ln -s ./docker-yocto-env/env ./env

## 3 To start environment, source the env file:
user/yocto_project% . ./env

## 4. All artefacts created by the environment in your YOCTO project should be added to the .gitignore file

DEPENDENCIES:
build_container: see <var-host-docker-containers> repo

## Docker image with environment for building Yocto image and SDK tools  
> Note: Build instructions was inhereted from Variscite with introduction of modern development technics  


### To build image, use following command:  
```
IMAGE_NAME=poky-vde
REGISTRY=roommatedev01.azurecr.io
VERSION=22.04
YOCTO_RELEASE=kirkstone
KIRKSTONE_SHA_ID=6505459809380ddcf152a09343e4dc55038de332

docker build -t "${REGISTRY}/${IMAGE_NAME}:${VERSION}" \
	--build-arg POKY_REPO=https://github.com/yoctoproject/poky.git \
	--build-arg POKY_COMMIT_ID=${KIRKSTONE_SHA_ID} \
	-f Dockerfile_${VERSION} .
```

As <REGISTRY>, use roommatedev01.azurecr.io  
As <VERSION>, use Ubuntu Linux Distribution version from following table:  
(If Dockerfile for some of the Ubuntu Distribution version is absent in this repo - Distribution was not tested and not approved to use)  

|                | Ubuntu 18.04 | Ubuntu 20.04 | Ubuntu 22.04 |  
|----------------|--------------|--------------|--------------|  
|Yocto Dunfell   |       X      |      X       |              |  
|Yocto Kirkstone |       X      |      X       |       X      |  
|Yocto Scarthgap |              |      X       |       X      |  

## Multiplatform builds  
### 1. Create BuildKit instance:  
```
docker buildx create --use --name buildx_instance
```

### 2. Build image for all needed target platforms  
```
docker buildx build --push  -t "${REGISTRY}/${IMAGE_NAME}:${YOCTO_RELEASE}-${VERSION}" \
        --platform linux/amd64,linux/arm64 \
        --builder buildx_instance \
        --build-arg POKY_REPO=https://github.com/yoctoproject/poky.git \
        --build-arg POKY_COMMIT_ID=${KIRKSTONE_SHA_ID} \
        -f Dockerfile_${VERSION} .
```

