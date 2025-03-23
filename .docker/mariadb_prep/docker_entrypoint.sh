#!/bin/bash

set -euo pipefail # Enable strict mode

# Check if the MYSQL_USER environment variable is set
if [ -z "$MYSQL_USER" ]; then
  echo "Error: MYSQL_USER environment variable is not set."
  exit 1
fi

# Define the input and output file paths
input_file="/install/user.sql"
output_dir="/docker-entrypoint-initdb.d/"
user_sql_out_file="03_user.sql"
registry_sql_out_file="01_registry.sql"
registrar_sql_out_file="02_registrar.sql"

# Check if the input file exists
if [ ! -f "$input_file" ]; then
  echo "Error: Input file '$input_file' not found."
  exit 1
fi

# Replace <MYSQL_USER> with the value of MYSQL_USER and save to the output file
sed "s/<MYSQL_USER>/$MYSQL_USER/g" "$input_file" > "$output_dir/$user_sql_out_file"

# Check if the sed command was successful
if [ $? -eq 0 ]; then
  echo "Successfully replaced <MYSQL_USER> and saved to '$output_dir/$user_sql_out_file'."
else
  echo "Error: Failed to replace <MYSQL_USER>."
  exit 1
fi

cat epp-1.0.15/sql/registry.sql | grep -v "GRANT " | grep -v "CREATE USER" > "$output_dir/$registry_sql_out_file"

#### PREPARE registry insert SQL

# Function to calculate SHA-1 base64 digest
sha1_base64() {
  local input="$1"
  echo -n "$input" | openssl sha1 -binary | base64
}

# Get current date in YYYY-MM-DD format
current_date=$(date +%Y-%m-%d)

# Replace REG_CR_DATE
replace_reg_cr_date() {
  sed "s/<REG_CR_DATE>/$current_date/g"
}

# Replace REG_PWD_HASH (calculate from REG_PWD if needed)
replace_reg_pwd_hash() {
  local reg_pwd_hash="${REG_PWD_HASH:-$(sha1_base64 "$REG_PWD")}"
  sed "s|<REG_PWD_HASH>|{SHA}$reg_pwd_hash|g"
}

# Replace all <VAR_NAME> expressions with corresponding env variable values
replace_env_vars() {
  while IFS= read -r line; do
    local pattern='<([A-Z_]+)>'
    while [[ $line =~ $pattern ]]; do
      local var_name="${BASH_REMATCH[1]}"
      local var_value=""
      if [[ -v "${var_name}" ]]; then
        var_value="${!var_name}"
      fi
      line=$(echo "$line" | sed "s|<${var_name}>|${var_value}|g")
    done
    echo "$line"
  done
}

cat "/install/create_registrar.sql" | replace_reg_cr_date | replace_reg_pwd_hash | replace_env_vars > "$output_dir/$registrar_sql_out_file"