# SPDX-License-Identifier: GPL-3.0-or-later
#
# This file is part of Nominatim. (https://nominatim.org)
#
# Copyright (C) 2025 by the Nominatim developer community.
# For a full list of authors see the git log.
"""
Tests for specialised connection and cursor classes.
"""
from types import SimpleNamespace

import pytest
import psycopg

import nominatim_db.db.connection as nc


@pytest.fixture
def db(dsn):
    with nc.connect(dsn) as conn:
        yield conn


def test_connection_table_exists(db, table_factory):
    assert not nc.table_exists(db, 'foobar')

    table_factory('foobar')

    assert nc.table_exists(db, 'foobar')


def test_has_column_no_table(db):
    assert not nc.table_has_column(db, 'sometable', 'somecolumn')


@pytest.mark.parametrize('name,result', [('tram', True), ('car', False)])
def test_has_column(db, table_factory, name, result):
    table_factory('stuff', 'tram TEXT')

    assert nc.table_has_column(db, 'stuff', name) == result


def test_connection_index_exists(db, table_factory, temp_db_cursor):
    assert not nc.index_exists(db, 'some_index')

    table_factory('foobar')
    temp_db_cursor.execute('CREATE INDEX some_index ON foobar(id)')

    assert nc.index_exists(db, 'some_index')
    assert nc.index_exists(db, 'some_index', table='foobar')
    assert not nc.index_exists(db, 'some_index', table='bar')


def test_drop_table_existing(db, table_factory):
    table_factory('dummy')
    assert nc.table_exists(db, 'dummy')

    nc.drop_tables(db, 'dummy')
    assert not nc.table_exists(db, 'dummy')


def test_drop_table_non_existing(db):
    nc.drop_tables(db, 'dfkjgjriogjigjgjrdghehtre')


def test_drop_many_tables(db, table_factory):
    tables = [f'table{n}' for n in range(5)]

    for t in tables:
        table_factory(t)
        assert nc.table_exists(db, t)

    nc.drop_tables(db, *tables)

    for t in tables:
        assert not nc.table_exists(db, t)


def test_drop_table_non_existing_force(db):
    with pytest.raises(psycopg.ProgrammingError, match='.*does not exist.*'):
        nc.drop_tables(db, 'dfkjgjriogjigjgjrdghehtre', if_exists=False)


def test_connection_server_version_tuple(db):
    ver = nc.server_version_tuple(db)

    assert isinstance(ver, tuple)
    assert len(ver) == 2
    assert ver[0] > 8


def test_connection_postgis_version_tuple(db, temp_db_with_extensions):
    ver = nc.postgis_version_tuple(db)

    assert isinstance(ver, tuple)
    assert len(ver) == 2
    assert ver[0] >= 2


def test_cursor_scalar(db, table_factory):
    table_factory('dummy')

    assert nc.execute_scalar(db, 'SELECT count(*) FROM dummy') == 0


def test_cursor_scalar_many_rows(db):
    with pytest.raises(RuntimeError, match='Query did not return a single row.'):
        nc.execute_scalar(db, 'SELECT * FROM pg_tables')


def test_cursor_scalar_no_rows(db, table_factory):
    table_factory('dummy')

    with pytest.raises(RuntimeError, match='Query did not return a single row.'):
        nc.execute_scalar(db, 'SELECT id FROM dummy')


def test_get_pg_env_add_variable(monkeypatch):
    monkeypatch.delenv('PGPASSWORD', raising=False)
    env = nc.get_pg_env('user=fooF')

    assert env['PGUSER'] == 'fooF'
    assert 'PGPASSWORD' not in env


def test_get_pg_env_overwrite_variable(monkeypatch):
    monkeypatch.setenv('PGUSER', 'some default')
    env = nc.get_pg_env('user=overwriter')

    assert env['PGUSER'] == 'overwriter'


def test_get_pg_env_ignore_unknown():
    env = nc.get_pg_env('client_encoding=stuff', base_env={})

    assert env == {}


def test_get_pg_env_fixes_root_home_for_non_root(monkeypatch):
    monkeypatch.setattr(nc.os, 'getuid', lambda: 1000)
    if nc.pwd is None:
        pytest.skip("pwd module not available")
    monkeypatch.setattr(nc.pwd, 'getpwuid',
                        lambda uid: SimpleNamespace(pw_dir='/var/lib/nominatim'))

    env = nc.get_pg_env('sslmode=require', base_env={'HOME': '/root'})

    assert env['HOME'] == '/var/lib/nominatim'


def test_get_pg_env_drops_root_default_ssl_client_cert_paths(monkeypatch):
    monkeypatch.setattr(nc.os, 'getuid', lambda: 1000)
    if nc.pwd is None:
        pytest.skip("pwd module not available")
    monkeypatch.setattr(nc.pwd, 'getpwuid',
                        lambda uid: SimpleNamespace(pw_dir='/var/lib/nominatim'))

    env = nc.get_pg_env('sslmode=require', base_env={
        'HOME': '/root',
        'PGSSLCERT': '/root/.postgresql/postgresql.crt',
        'PGSSLKEY': '/root/.postgresql/postgresql.key',
    })

    assert 'PGSSLCERT' not in env
    assert 'PGSSLKEY' not in env


def test_get_pg_env_keeps_explicit_ssl_client_cert_paths():
    env = nc.get_pg_env('sslmode=require sslcert=/tmp/client.crt sslkey=/tmp/client.key',
                        base_env={})

    assert env['PGSSLCERT'] == '/tmp/client.crt'
    assert env['PGSSLKEY'] == '/tmp/client.key'
