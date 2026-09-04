"""Minimal Firestore REST + Storage JSON API client. Built as a real
workaround, not a preference: the google-cloud-firestore Python client
defaults to gRPC, which hangs indefinitely through this sandbox's HTTPS
proxy (confirmed: plain HTTPS to the same hosts works fine, gRPC calls to
firestore.googleapis.com never return). REST calls to the same project work
immediately. google-cloud-storage already uses the plain JSON/HTTP API, not
gRPC, so it is unaffected and used directly (not reimplemented here).
"""
import os
import requests
from google.oauth2 import service_account
from google.auth.transport.requests import Request

PROJECT = 'clearbridge-dc699'
CREDS_PATH = '/tmp/creds/sa.json'

_creds = None


def _token():
    global _creds
    if _creds is None:
        _creds = service_account.Credentials.from_service_account_file(
            CREDS_PATH, scopes=['https://www.googleapis.com/auth/datastore'])
    if not _creds.valid:
        _creds.refresh(Request())
    return _creds.token


def _decode_value(v):
    if 'stringValue' in v:
        return v['stringValue']
    if 'doubleValue' in v:
        return v['doubleValue']
    if 'integerValue' in v:
        return int(v['integerValue'])
    if 'booleanValue' in v:
        return v['booleanValue']
    if 'nullValue' in v:
        return None
    if 'timestampValue' in v:
        return v['timestampValue']
    if 'mapValue' in v:
        return {k: _decode_value(vv) for k, vv in v['mapValue'].get('fields', {}).items()}
    if 'arrayValue' in v:
        return [_decode_value(x) for x in v['arrayValue'].get('values', [])]
    if 'referenceValue' in v:
        return v['referenceValue']
    return None


def get_doc(collection, doc_id):
    url = ('https://firestore.googleapis.com/v1/projects/%s/databases/(default)'
           '/documents/%s/%s') % (PROJECT, collection, doc_id)
    r = requests.get(url, headers={'Authorization': 'Bearer %s' % _token()}, timeout=30)
    r.raise_for_status()
    fields = r.json().get('fields', {})
    return {k: _decode_value(v) for k, v in fields.items()}


def query_latest(collection, order_field='createdAt', limit=5):
    url = ('https://firestore.googleapis.com/v1/projects/%s/databases/(default)'
           '/documents:runQuery') % PROJECT
    body = {'structuredQuery': {
        'from': [{'collectionId': collection}],
        'orderBy': [{'field': {'fieldPath': order_field}, 'direction': 'DESCENDING'}],
        'limit': limit,
    }}
    r = requests.post(url, headers={'Authorization': 'Bearer %s' % _token()}, json=body, timeout=30)
    r.raise_for_status()
    out = []
    for item in r.json():
        doc = item.get('document')
        if not doc:
            continue
        name = doc['name']
        doc_id = name.rsplit('/', 1)[-1]
        fields = doc.get('fields', {})
        out.append((doc_id, {k: _decode_value(v) for k, v in fields.items()}))
    return out
