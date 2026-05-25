"""Pytest tests for src/app.py.

Run locally with:
    cd io107-lab2-sam-app
    pip install pytest
    PYTHONPATH=src pytest tests/ -v

The pipeline buildspec also runs `pytest tests/` in the pre_build phase.
"""

import json
import os
import sys

# Make src/ importable regardless of where pytest is launched from.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))

from app import handler  # noqa: E402


def _api_event(path, method, body=None):
    """Build a minimal API Gateway proxy event."""
    return {
        'path': path,
        'httpMethod': method,
        'body': body,
        'headers': {},
        'queryStringParameters': None,
    }


def test_health_returns_200():
    response = handler(_api_event('/health', 'GET'), None)
    assert response['statusCode'] == 200
    body = json.loads(response['body'])
    assert body['status'] == 'ok'


def test_get_items_returns_200_with_items_array():
    response = handler(_api_event('/items', 'GET'), None)
    assert response['statusCode'] == 200
    body = json.loads(response['body'])
    assert 'items' in body
    assert isinstance(body['items'], list)
    assert len(body['items']) >= 1
    # Every item should have id and name fields.
    for item in body['items']:
        assert 'id' in item
        assert 'name' in item


def test_unknown_path_returns_404():
    response = handler(_api_event('/does-not-exist', 'GET'), None)
    assert response['statusCode'] == 404
    body = json.loads(response['body'])
    assert body['error'] == 'Not found'


def test_unknown_method_on_items_returns_404():
    """Until students complete Task 4, POST /items is not registered → 404."""
    response = handler(_api_event('/items', 'DELETE'), None)
    assert response['statusCode'] == 404


def test_response_body_is_json_string():
    """API Gateway proxy integration requires body to be a string, not a dict."""
    response = handler(_api_event('/health', 'GET'), None)
    assert isinstance(response['body'], str)
    # And it must parse as valid JSON.
    json.loads(response['body'])
