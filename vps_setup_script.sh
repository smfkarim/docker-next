#!/bin/bash

# VPS Setup Script for Next.js + Docker + Nginx + SSL + GitHub Actions
# Run this script on your VPS as root or with sudo privileges

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_info "Starting VPS setup for Next.js deployment..."

# Get configuration from user
read -p "Enter your domain name (e.g., example.com): " DOMAIN
read -p "Enter your email for SSL certificates: " EMAIL
read -p "Enter your Docker Hub username: " DOCKER_USERNAME
read -s -p "Enter your Docker Hub password/token: " DOCKER_PASSWORD
echo
read -p "Enter your GitHub username: " GITHUB_USERNAME
read -p "Enter your GitHub repository name: " REPO_NAME

# Validate inputs
if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$DOCKER_USERNAME" || -z "$DOCKER_PASSWORD" || -z "$GITHUB_USERNAME" || -z "$REPO_NAME" ]]; then
    print_error "All fields are required!"
    exit 1
fi

print_info "Configuration received. Starting setup..."

# Update system packages
print_info "Updating system packages..."
apt update && apt upgrade -y

# Install Docker if not already installed
if ! command_exists docker; then
    print_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl start docker
    systemctl enable docker
    usermod -aG docker $USER
    rm get-docker.sh
    print_success "Docker installed successfully"
else
    print_info "Docker is already installed"
fi

# Install Docker Compose if not already installed
if ! command_exists docker-compose; then
    print_info "Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose installed successfully"
else
    print_info "Docker Compose is already installed"
fi

# Install certbot and nginx plugin
print_info "Installing Certbot..."
apt install -y snapd
snap install core; snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# Create project directory
PROJECT_DIR="/opt/${REPO_NAME}"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# Create docker-compose.yml
print_info "Creating docker-compose.yml..."
cat > docker-compose.yml << EOF
version: '3.8'

services:
  app:
    image: ${DOCKER_USERNAME}/${REPO_NAME}:latest
    container_name: ${REPO_NAME}-app
    restart: unless-stopped
    environment:
      - NODE_ENV=production
    networks:
      - app-network

  nginx:
    image: nginx:alpine
    container_name: ${REPO_NAME}-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /var/www/certbot:/var/www/certbot:ro
    depends_on:
      - app
    networks:
      - app-network

networks:
  app-network:
    driver: bridge
EOF

# Create nginx configuration
print_info "Creating Nginx configuration..."
cat > nginx.conf << EOF
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=api:10m rate=10r/s;

    # Upstream for the app
    upstream app {
        server app:3000;
    }

    # HTTP server - redirect to HTTPS
    server {
        listen 80;
        server_name ${DOMAIN} www.${DOMAIN};

        # Certbot challenge location
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        # Redirect all HTTP to HTTPS
        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    # HTTPS server
    server {
        listen 443 ssl http2;
        server_name ${DOMAIN} www.${DOMAIN};

        # SSL configuration
        ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;

        # Security headers
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";

        # Proxy to Next.js app
        location / {
            proxy_pass http://app;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_cache_bypass \$http_upgrade;
            
            # Rate limiting
            limit_req zone=api burst=20 nodelay;
        }

        # Static files caching
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
            proxy_pass http://app;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
}
EOF

# Generate initial SSL certificate
print_info "Generating initial SSL certificate..."
mkdir -p /var/www/certbot

# Start nginx temporarily for certificate generation
docker run --rm -d --name temp-nginx \
    -p 80:80 \
    -v $(pwd)/temp-nginx.conf:/etc/nginx/nginx.conf:ro \
    -v /var/www/certbot:/var/www/certbot:ro \
    nginx:alpine

# Create temporary nginx config for certificate generation
cat > temp-nginx.conf << EOF
events {
    worker_connections 1024;
}
http {
    server {
        listen 80;
        server_name ${DOMAIN} www.${DOMAIN};
        
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }
        
        location / {
            return 200 "OK";
        }
    }
}
EOF

# Generate SSL certificate
certbot certonly --webroot --webroot-path=/var/www/certbot --email $EMAIL --agree-tos --no-eff-email -d $DOMAIN -d www.$DOMAIN

# Stop temporary nginx
docker stop temp-nginx
rm temp-nginx.conf

# Setup SSL auto-renewal
print_info "Setting up SSL auto-renewal..."
cat > /etc/systemd/system/certbot-renewal.service << EOF
[Unit]
Description=Certbot Renewal
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --webroot --webroot-path=/var/www/certbot --post-hook "cd ${PROJECT_DIR} && docker-compose restart nginx"
EOF

cat > /etc/systemd/system/certbot-renewal.timer << EOF
[Unit]
Description=Run certbot renewal twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable certbot-renewal.timer
systemctl start certbot-renewal.timer

# Generate SSH keypair for GitHub Actions
print_info "Generating SSH keypair for GitHub Actions..."
SSH_DIR="/root/.ssh"
mkdir -p $SSH_DIR
ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/github_actions" -N "" -C "github-actions@${DOMAIN}"

# Add public key to authorized_keys
cat "$SSH_DIR/github_actions.pub" >> "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chmod 700 $SSH_DIR

# Configure Docker Hub login
print_info "Configuring Docker Hub login..."
echo $DOCKER_PASSWORD | docker login -u $DOCKER_USERNAME --password-stdin

# Create deployment script
print_info "Creating deployment script..."
cat > deploy.sh << 'EOF'
#!/bin/bash
set -e

# Pull latest images
docker-compose pull

# Restart services
docker-compose up -d

# Clean up old images
docker image prune -f

echo "Deployment completed successfully!"
EOF

chmod +x deploy.sh

# Create GitHub workflow file
print_info "Creating GitHub Actions workflow..."
WORKFLOW_DIR=".github/workflows"
mkdir -p $WORKFLOW_DIR

cat > "$WORKFLOW_DIR/deploy.yml" << EOF
name: Build and Deploy

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4
    
    - name: Set up Node.js
      uses: actions/setup-node@v4
      with:
        node-version: '18'
        cache: 'npm'
    
    - name: Install dependencies
      run: npm ci
    
    - name: Run tests
      run: npm test -- --passWithNoTests
    
    - name: Build application
      run: npm run build
    
    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3
    
    - name: Login to Docker Hub
      uses: docker/login-action@v3
      with:
        username: \${{ secrets.DOCKER_USERNAME }}
        password: \${{ secrets.DOCKER_PASSWORD }}
    
    - name: Build and push Docker image
      uses: docker/build-push-action@v5
      with:
        context: .
        push: true
        tags: ${DOCKER_USERNAME}/${REPO_NAME}:latest
        cache-from: type=gha
        cache-to: type=gha,mode=max
    
    - name: Deploy to VPS
      if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/master'
      uses: appleboy/ssh-action@v1.0.0
      with:
        host: \${{ secrets.VPS_HOST }}
        username: \${{ secrets.VPS_USERNAME }}
        key: \${{ secrets.VPS_SSH_KEY }}
        script: |
          cd ${PROJECT_DIR}
          ./deploy.sh
EOF

# Create sample Dockerfile if it doesn't exist
if [ ! -f "Dockerfile" ]; then
    print_info "Creating sample Dockerfile..."
    cat > Dockerfile << EOF
FROM node:18-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci --only=production

# Copy source code
COPY . .

# Build the application
RUN npm run build

EXPOSE 3000

CMD ["npm", "start"]
EOF
fi

# Display the information needed for GitHub Secrets
print_success "Setup completed! Please add the following secrets to your GitHub repository:"
echo
print_warning "GitHub Secrets to add:"
echo "=========================="
echo "VPS_HOST: $(curl -s ifconfig.me)"
echo "VPS_USERNAME: root"
echo "VPS_SSH_KEY:"
echo "$(cat $SSH_DIR/github_actions)"
echo
echo "DOCKER_USERNAME: $DOCKER_USERNAME"
echo "DOCKER_PASSWORD: [Your Docker Hub password/token]"
echo
echo "=========================="
echo
print_info "To add these secrets:"
echo "1. Go to your GitHub repository"
echo "2. Click Settings → Secrets and variables → Actions"
echo "3. Click 'New repository secret' for each secret above"
echo
print_info "Additional setup notes:"
echo "- Make sure your domain DNS points to this server's IP: $(curl -s ifconfig.me)"
echo "- The workflow file has been created at: $WORKFLOW_DIR/deploy.yml"
echo "- SSL certificates will auto-renew twice daily"
echo "- Your app will be accessible at: https://$DOMAIN"
echo
print_info "To start your services:"
echo "cd $PROJECT_DIR && docker-compose up -d"
echo
print_success "VPS setup completed successfully!"
