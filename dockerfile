FROM container-registry.oracle.com/database/express:21.3.0-xe

# Set environment variables
ENV ORACLE_PWD=Password123
ENV ORACLE_PASSWORD=Password123

# Expose Oracle ports
EXPOSE 1521 5500