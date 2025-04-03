# Use the official PHP 8.1 FPM image
FROM php:8.1-fpm

# Install dependencies and PHP extensions
RUN apt-get update && apt-get install -y \
    libzip-dev \
    unzip \
    default-mysql-client \
    && docker-php-ext-install mysqli pdo pdo_mysql zip

# Install WP-CLI
RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

# Set working directory
WORKDIR /var/www/html/

# Copy the application code
COPY . /var/www/html/

# Set permissions
RUN chown -R www-data:www-data /var/www/html
