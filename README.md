# Nginx Proxy Auto Install

A user friendly bash script that automates setting up Nginx reverse proxy configurations. Because life's too short to manually edit config files.

## What Problem Does This Solve?

If you've ever deployed an application (Node.js, Python, React, etc.) that runs on a specific port (like 3000, 8000, or 8080), you know the struggle: people can't access it directly by port number, and setting up proper domain routing with SSL is a pain.

This script handles the boring parts for you. It creates the bridge between your domain name and your application, with optional HTTPS encryption - because nobody likes angry browser security warnings.

## Key Features

- **Simple Menu Interface**: No memorizing complex commands or flags  
- **Input Validation**: It catches typos and silly mistakes so you don't have to  
- **SSL/TLS Setup**: Automatic Let's Encrypt certificate configuration  
- **Clean Removal**: Easily undo what you've created  

## Installation & Usage

```bash
bash <(curl -s https://raw.githubusercontent.com/joaquimvr/Nginx-reverse-proxy-install/main/install.sh)
```
Yes, it's that simple. The script will guide you through the rest.

  - Run the installation command above

  - Answer the simple questions (backend IP/port, domain name, etc.)

  - Let the script handle the Nginx configuration, SSL setup, and firewall rules

  - Test your new professionally-proxied application

## Managing Configurations

Changed your mind? Need to remove a proxy configuration? Just run the script again and select option 3 from the menu. It will show you all active configurations and let you clean up what you don't need.

If something goes wrong (because computers sometimes enjoy being difficult)
feel free to create an issue on this github repo, happy to assist.

**Important Note:**

This script is provided as-is. While it's been tested and should work smoothly, always understand what a script does before running it on your server.
