"""IO-107 Lab 2 — Serverless API handler.

This module is the starting state students clone in Task 1. In Task 4 they add
a third route branch (POST /items -> create_item) plus the create_item function.

The handler returns the API Gateway proxy integration response shape:
    {"statusCode": <int>, "body": <json string>}
"""

import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(os.environ.get('LOG_LEVEL', 'INFO'))

# Mock data — in a real implementation this would come from Aurora/RDS.
_ITEMS = [
    {'id': 1, 'name': 'Item 1'},
    {'id': 2, 'name': 'Item 2'},
    {'id': 3, 'name': 'Item 3'},
]


def handler(event, context):
    """Lambda entry point. Routes on event['path'] and event['httpMethod']."""
    path = event.get('path', '')
    method = event.get('httpMethod', '')
    logger.info(f"Request: {method} {path}")

    if path == '/health':
        return health_check()
    elif path == '/items' and method == 'GET':
        return get_items()
    # Task 4: students add the POST /items branch here.
    # elif path == '/items' and method == 'POST':
    #     return create_item(event)
    else:
        return {
            'statusCode': 404,
            'body': json.dumps({'error': 'Not found'})
        }


def health_check():
    """Liveness probe — returns 200 if the function is invokable."""
    return {
        'statusCode': 200,
        'body': json.dumps({'status': 'ok'})
    }


def get_items():
    """Return the mock items list."""
    return {
        'statusCode': 200,
        'body': json.dumps({'items': _ITEMS})
    }


# Students add this function in Task 4:
#
# def create_item(event):
#     try:
#         body = json.loads(event.get('body', '{}'))
#         name = body.get('name', 'Unnamed')
#         new_item = {'id': 4, 'name': name, 'created': True}
#         logger.info(f"Created item: {new_item}")
#         return {
#             'statusCode': 201,
#             'body': json.dumps(new_item)
#         }
#     except json.JSONDecodeError:
#         return {
#             'statusCode': 400,
#             'body': json.dumps({'error': 'Invalid JSON'})
#         }
