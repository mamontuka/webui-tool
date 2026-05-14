#!/usr/bin/env python3
import psycopg2
import json
import argparse
import os
import sys
import fnmatch
from datetime import datetime

# Параметры подключения строго из ENV
DB_CONFIG = {
    'host': os.getenv('OW_DB_HOST', 'localhost'),
    'port': int(os.getenv('OW_DB_PORT', 5432)),
    'database': os.getenv('OW_DB_NAME', 'openwebui'),
    'user': os.getenv('OW_DB_USER', 'openwebui'),
    'password': os.getenv('OW_DB_PASSWORD', 'openwebui')  # Пароль
}

DONOR_EMAIL = 'user@host.com' # пользователь от которого мы берем шаблон настроек

def log(msg, level='info'):
    prefix = {'info': 'ℹ️', 'warn': '⚠️', 'error': '❌', 'success': '✅', 'prompt': '🔹', 'diff': '📊'}
    print(f"{prefix.get(level, '•')} {msg}")

def ask_user(prompt, default=False):
    suffix = "[Y/n]" if default else "[y/N]"
    try:
        resp = input(f"{prompt} {suffix}: ").strip().lower()
        if not resp:
            return default
        return resp in ('y', 'yes', 'да', 'д')
    except (EOFError, KeyboardInterrupt):
        print("\n🚫 Прервано пользователем")
        sys.exit(0)

def check_environment():
    """Проверка зависимостей и переменных окружения"""
    errors = []
    if not DB_CONFIG['password']:
        errors.append("Не задан OW_DB_PASSWORD")
    for key in ['host', 'database', 'user']:
        if not DB_CONFIG[key]:
            errors.append(f"Не задан OW_DB_{key.upper()}")
    
    if errors:
        log("❌ Ошибки конфигурации:", 'error')
        for e in errors:
            print(f"   • {e}")
        sys.exit(1)
    
    try:
        import psycopg2
    except ImportError:
        log("❌ Не установлен psycopg2. Установи: pip install psycopg2-binary", 'error')
        sys.exit(1)

def matches_filter(email, include_patterns, exclude_patterns):
    """Проверка email по glob-шаблонам"""
    if include_patterns:
        if not any(fnmatch.fnmatch(email, p) for p in include_patterns):
            return False
    if exclude_patterns:
        if any(fnmatch.fnmatch(email, p) for p in exclude_patterns):
            return False
    return True

def create_backup(cur, users, backup_path):
    """Создание JSON бэкапа пользователей"""
    backup_data = {
        'created_at': datetime.now().isoformat(),
        'users': []
    }
    for user_id, email, settings in users:
        backup_data['users'].append({
            'id': user_id,
            'email': email,
            'settings': settings
        })
    
    dir_name = os.path.dirname(backup_path)
    if dir_name:
        os.makedirs(dir_name, exist_ok=True)
        
    with open(backup_path, 'w', encoding='utf-8') as f:
        json.dump(backup_data, f, indent=2, ensure_ascii=False)
    log(f"💾 Бэкап сохранён: {backup_path}", 'success')

def migrate_settings(args):
    conn = None
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()

        # Проверка соединения
        try:
            cur.execute('SELECT 1')
        except Exception as e:
            log(f"❌ Ошибка подключения к БД: {e}", 'error')
            sys.exit(1)

        # Получаем донора
        cur.execute('SELECT id, settings FROM "user" WHERE email = %s', (DONOR_EMAIL,))
        donor = cur.fetchone()
        if not donor:
            raise Exception(f"Пользователь {DONOR_EMAIL} не найден")
        
        donor_id, donor_settings = donor
        donor_json = json.loads(donor_settings) if isinstance(donor_settings, str) else donor_settings
        log(f"✓ Донор найден: ID={donor_id}")

        # Сбор кандидатов
        candidates = {}
        ui_data = donor_json.get('ui', {})

        if 'audio' in ui_data:
            candidates['ui.audio'] = {'path': ['ui', 'audio'], 'value': ui_data['audio']}

        pinned = ui_data.get('pinnedModels') or donor_json.get('pinned_models')
        if pinned:
            candidates['pinned_models'] = {
                'path': ['pinned_models'], 
                'value': pinned, 
                'ui_key': 'pinnedModels'
            }

        if 'directConnections' in ui_data:
            candidates['ui.directConnections'] = {
                'path': ['ui', 'directConnections'], 
                'value': ui_data['directConnections'],
                'danger': True
            }

        for key, value in ui_data.items():
            if key in ('audio', 'directConnections', 'pinnedModels'):
                continue
            candidates[f'ui.{key}'] = {'path': ['ui', key], 'value': value}

        # Выбор параметров
        selected_keys = []

        if args.interactive:
            log("🎛️ ИНТЕРАКТИВНЫЙ РЕЖИМ", 'info')
            print("-" * 60)
            for key, info in candidates.items():
                danger_mark = " ⚠️ API-KEYS!" if info.get('danger') else ""
                if ask_user(f"Копировать {key}{danger_mark}?", default=False):
                    selected_keys.append(key)
            print("-" * 60)
            
            if not selected_keys:
                log("Ничего не выбрано, выход.", 'warn')
                return
        else:
            if args.copy_all_ui:
                selected_keys.extend([k for k in candidates if not k.startswith('ui.directConnections')])
            if args.copy_pinned_models and 'pinned_models' in candidates:
                selected_keys.append('pinned_models')
            if args.copy_direct_connections and 'ui.directConnections' in candidates:
                if args.yes or ask_user("⚠️ Копировать directConnections?", default=False):
                    selected_keys.append('ui.directConnections')

        if not selected_keys:
            log("Нет параметров для копирования.", 'warn')
            return

        log(f"📦 Выбрано: {', '.join(selected_keys)}")

        # Получаем пользователей с фильтрацией
        cur.execute('SELECT id, email, settings FROM "user" WHERE email != %s', (DONOR_EMAIL,))
        all_users = cur.fetchall()

        include_patterns = args.include_emails.split(',') if args.include_emails else []
        exclude_patterns = args.exclude_emails.split(',') if args.exclude_emails else []

        users = [u for u in all_users if matches_filter(u[1], include_patterns, exclude_patterns)]
        filtered_out = len(all_users) - len(users)

        if filtered_out > 0:
            log(f"🔍 Отфильтровано пользователей: {filtered_out}", 'info')

        if not users:
            log("Нет пользователей для обновления после фильтрации.", 'warn')
            return

        # Режим diff
        if args.diff:
            log("📊 РЕЖИМ СРАВНЕНИЯ (DIFF)", 'info')
            print("-" * 60)
            diff_count = 0
            for user_id, email, user_settings in users:
                user_json = json.loads(user_settings) if isinstance(user_settings, str) else (user_settings or {})
                diffs = []
                for key in selected_keys:
                    info = candidates[key]
                    target = user_json
                    for p in info['path'][:-1]:
                        target = target.get(p, {})
                    current_val = target.get(info['path'][-1])
                    if current_val != info['value']:
                        diffs.append(key)
                if diffs:
                    log(f"📊 {email}: отличаются {', '.join(diffs)}", 'diff')
                    diff_count += 1
                elif args.verbose:
                    log(f"  ✓ {email}: без изменений")
            print("-" * 60)
            log(f"Итого: {diff_count} пользователей имеют отличия", 'info')
            return

        # Бэкап
        if args.backup:
            backup_path = args.backup
            if '{date}' in backup_path:
                backup_path = backup_path.replace('{date}', datetime.now().strftime('%Y%m%d_%H%M%S'))
            create_backup(cur, users, backup_path)

        # Применение
        if args.dry_run:
            log(f"🔍 DRY-RUN: будет обновлено {len(users)} пользователей", 'warn')
        else:
            updated = 0
            for user_id, email, user_settings in users:
                user_json = json.loads(user_settings) if isinstance(user_settings, str) else (user_settings or {})
                
                for key in selected_keys:
                    info = candidates[key]
                    target = user_json
                    path = info['path']
                    for p in path[:-1]:
                        target = target.setdefault(p, {})
                    target[path[-1]] = info['value']
                    
                    if key == 'pinned_models' and 'ui_key' in info:
                        user_json.setdefault('ui', {})[info['ui_key']] = info['value']

                cur.execute("""
                    UPDATE "user" SET settings = %s::jsonb, updated_at = EXTRACT(EPOCH FROM NOW()) * 1000
                    WHERE id = %s
                """, (json.dumps(user_json), user_id))
                updated += 1
                
                if args.verbose or updated <= 5 or updated % 10 == 0:
                    log(f"  ✓ {email}")
            
            conn.commit()
            log(f"✅ Готово! Обновлено: {updated}", 'success')

    except Exception as e:
        if conn:
            conn.rollback()
            log("🔄 Откат транзакции", 'warn')
        log(f"❌ Ошибка: {e}", 'error')
        raise
    finally:
        if conn:
            conn.close()

if __name__ == '__main__':
    # Проверка окружения при старте
    check_environment()

    parser = argparse.ArgumentParser(
        description='🔄 Миграция настроек OpenWebUI',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Примеры:
  %(prog)s -i                       # Интерактивный выбор параметров
  %(prog)s -a -p                    # Все UI + pinned_models
  %(prog)s --diff                   # Показать отличия без изменений
  %(prog)s -i --backup backup.json  # Интерактивно с бэкапом
  %(prog)s -a --include "admin@*"   # Только админы
  %(prog)s --dry-run -v             # Тестовый прогон с логом
        '''
    )
    parser.add_argument('-i', '--interactive', action='store_true', help='Интерактивный выбор параметров')
    parser.add_argument('-p', '--copy-pinned-models', action='store_true', help='Копировать pinned_models')
    parser.add_argument('-d', '--copy-direct-connections', action='store_true', help='Копировать directConnections')
    parser.add_argument('-a', '--copy-all-ui', action='store_true', help='Копировать все UI настройки')
    parser.add_argument('--dry-run', action='store_true', help='Тестовый режим')
    parser.add_argument('-y', '--yes', action='store_true', help='Пропустить подтверждения')
    parser.add_argument('-v', '--verbose', action='store_true', help='Подробный лог')
    parser.add_argument('--diff', action='store_true', help='Режим сравнения без изменений')
    parser.add_argument('--backup', metavar='PATH', help='Создать бэкап перед записью (поддерживает {date})')
    parser.add_argument('--include-emails', metavar='PATTERNS', help='Шаблоны email для включения (через запятую)')
    parser.add_argument('--exclude-emails', metavar='PATTERNS', help='Шаблоны email для исключения (через запятую)')
    
    args = parser.parse_args()

    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)

    print("\n" + "="*60)
    print("🔄 WebUI Settings Migrator")
    print(f"📧 Донор: {DONOR_EMAIL}")
    print(f"🎛️ Режим: {'Интерактивный' if args.interactive else 'Автоматический'}")
    if args.diff:
        print("📊 Diff: включен")
    if args.backup:
        print(f"💾 Бэкап: {args.backup}")
    print("="*60 + "\n")

    migrate_settings(args)
  
