#!/bin/bash

# Скрипт для запуска LangGraph Studio
# Использование: ./start-langgraph-studio.sh

set -e

echo "🚀 Запуск LangGraph Studio..."
echo ""

# Проверка наличия .env файла
if [ ! -f .env ]; then
    echo "⚠️  Внимание: файл .env не найден!"
    echo "   Создайте файл .env на основе env.example"
    echo ""
fi

# Проверка установки langgraph-cli
if ! command -v langgraph &> /dev/null; then
    echo "❌ langgraph-cli не установлен!"
    echo "   Установите зависимости: pip install -r requirements.txt"
    exit 1
fi

# Проверка наличия langgraph.json
if [ ! -f langgraph.json ]; then
    echo "❌ Файл langgraph.json не найден!"
    exit 1
fi

# Установка пакета в режиме разработки (если еще не установлен)
echo "📦 Проверка установки пакета..."
if ! python -c "import langgraph_server" 2>/dev/null; then
    echo "   Установка пакета в режиме разработки..."
    pip install -e . > /dev/null 2>&1 || {
        echo "⚠️  Не удалось установить пакет автоматически"
        echo "   Попробуйте вручную: pip install -e ."
    }
fi

echo "✅ Все проверки пройдены"
echo ""
echo "📊 Запуск LangGraph Studio..."
echo "   Studio будет доступен по адресу: https://smith.langchain.com/studio/"
echo "   API будет доступен по адресу: http://127.0.0.1:2024"
echo "   Нажмите Ctrl+C для остановки"
echo ""

# Запуск LangGraph Studio
langgraph dev

