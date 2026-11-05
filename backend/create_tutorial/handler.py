import json
import os
import socket


def lambda_handler(event, context):
    host = os.environ["DB_HOST"]
    port = int(os.environ["DB_PORT"])

    # Plain TCP connection: proves the network path, no login, no SQL.
    try:
        with socket.create_connection((host, port), timeout=5):
            reachable, error = True, None
    except OSError as exc:
        reachable, error = False, str(exc)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "function": os.environ["AWS_LAMBDA_FUNCTION_NAME"],
            "db_host": host,
            "db_port": port,
            "db_reachable": reachable,
            "error": error,
        }),
    }
