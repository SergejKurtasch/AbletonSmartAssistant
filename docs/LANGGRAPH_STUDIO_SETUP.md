# Настройка LangGraph Studio для визуализации архитектуры

Это руководство поможет вам настроить LangGraph Studio для визуализации архитектуры вашего LangGraph workflow.

## Что такое LangGraph Studio?

LangGraph Studio - это визуальный инструмент для просмотра, отладки и тестирования LangGraph workflows. Он позволяет:
- Визуально видеть всю архитектуру графа
- Отслеживать выполнение workflow в реальном времени
- Тестировать ноды и переходы
- Просматривать состояние на каждом шаге

## Установка

### 1. Установите зависимости

```bash
# Установите зависимости из requirements.txt
pip install -r requirements.txt

# Установите пакет в режиме разработки (важно для LangGraph Studio)
pip install -e .
```

Это установит `langgraph-cli`, все необходимые зависимости и сам пакет `langgraph_server` в режиме разработки, что необходимо для корректной работы импортов.

### 2. Проверьте конфигурацию

Убедитесь, что файл `langgraph.json` существует в корне проекта:

```json
{
  "dependencies": ["."],
  "graphs": {
    "agent": "./langgraph_server/workflow.py:create_workflow"
  },
  "env": ".env"
}
```

### 3. Настройте переменные окружения

Убедитесь, что файл `.env` существует и содержит необходимые переменные:

```bash
OPENAI_API_KEY=your_api_key_here
OPENAI_MODEL=gpt-4o
VISION_MODEL=gpt-4o
LANGGRAPH_SERVER_HOST=0.0.0.0
LANGGRAPH_SERVER_PORT=8000

# Опционально: LangSmith API key для мониторинга в Studio
# БЕЗ этого ключа Studio все равно работает, просто не будет отправлять данные в LangSmith
# LANGSMITH_API_KEY=lsv2_pt_your-key-here
```

**Важно:** LangSmith API key **не обязателен** для работы Studio. Он используется только для отправки данных о выполнении workflow в LangSmith для мониторинга. Studio будет работать и без него, просто вы не увидите трассировки в LangSmith.

## Запуск LangGraph Studio

### Локальный режим (рекомендуется)

Запустите LangGraph Studio локально:

```bash
langgraph dev
```

Эта команда:
1. Запустит локальный сервер LangGraph Studio
2. Откроет браузер с визуализацией workflow
3. Позволит тестировать workflow интерактивно

По умолчанию Studio будет доступен по адресу: `http://localhost:8123`

### Альтернативный способ - через LangGraph Cloud

Если вы хотите использовать облачную версию:

1. Зарегистрируйтесь на [cloud.langchain.com](https://cloud.langchain.com)
2. Создайте новый проект
3. Задеплойте workflow:

```bash
langgraph deploy
```

## Использование Studio

### Просмотр архитектуры

После запуска `langgraph dev` вы увидите:

1. **Граф workflow** - визуальное представление всех нод и переходов
2. **Список нод** - все ноды вашего workflow:
   - `detect_intent` - Определение намерения пользователя
   - `check_version` - Проверка совместимости версии Ableton
   - `wait_version_choice` - Ожидание выбора пользователя
   - `retrieve` - Поиск в векторной базе данных
   - `generate_answer` - Генерация полного ответа
   - `wait_step_choice` - Ожидание выбора режима (пошаговый/простой)
   - `step_agent` - Инициализация пошагового режима
   - `detect_interaction` - Определение типа взаимодействия
   - `analyze_screenshot` - Анализ скриншота для поиска кнопок
   - `wait_action` - Ожидание действия пользователя
   - `validate` - Валидация выполненного шага
   - `next_step` - Переход к следующему шагу
   - `final_confirmation` - Финальное подтверждение
   - `fallback` - Fallback ветка для повторного прохождения шагов

3. **Условные переходы** - все условные рёбра графа с их условиями

### Тестирование workflow

В Studio вы можете:

1. **Запустить workflow** с тестовыми данными
2. **Проследить выполнение** - видеть, какие ноды выполняются
3. **Просмотреть состояние** - видеть состояние на каждом шаге
4. **Отладить проблемы** - найти, где workflow застревает или падает

### Пример тестового состояния

Для тестирования в Studio используйте следующее начальное состояние:

```json
{
  "session_id": "test-session-123",
  "user_query": "Как создать новый проект в Ableton?",
  "ableton_edition": "Ableton Live Suite",
  "conversation_history": [],
  "screenshot_url": null,
  "intent": null,
  "allowed": null,
  "version_explanation": null,
  "selected_chunks": [],
  "full_answer": null,
  "steps": [],
  "current_step_index": 0,
  "mode": "simple",
  "user_choice": null,
  "action_required": null,
  "response_text": null
}
```

## Структура Workflow

### Основной поток

1. **detect_intent** → Определяет, относится ли вопрос к Ableton
   - Если `other` → END
   - Если `ableton_question` → **check_version**

2. **check_version** → Проверяет совместимость версии
   - Если `allowed == false` → **wait_version_choice**
   - Если `allowed == true` → **retrieve**

3. **wait_version_choice** → Ожидает выбор пользователя
   - Если "новая задача" → END
   - Если "попробовать" → **retrieve**

4. **retrieve** → Поиск в векторной БД → **generate_answer**

5. **generate_answer** → Генерация ответа → **wait_step_choice**

6. **wait_step_choice** → Предложение пошагового режима
   - Если "да" → **step_agent**
   - Если "нет" → END

### Пошаговый режим

7. **step_agent** → Инициализация → **detect_interaction**

8. **detect_interaction** → Определение типа взаимодействия
   - Если `requires_click == true` → **analyze_screenshot**
   - Если `requires_click == false` → **wait_action**

9. **analyze_screenshot** → Анализ скриншота → **wait_action**

10. **wait_action** → Ожидание действия пользователя
    - Если "отменить" → END
    - Если "пропустить" → **next_step**
    - Иначе → **validate**

11. **validate** → Валидация шага → **next_step**

12. **next_step** → Переход к следующему шагу
    - Если есть ещё шаги → **detect_interaction** (цикл)
    - Если все шаги выполнены → **final_confirmation**

13. **final_confirmation** → Финальное подтверждение
    - Если "да" → END
    - Если "нет" → **fallback**

14. **fallback** → Повторный анализ шагов → **step_agent**

## Устранение проблем

### Сообщение: "LangSmith API key is missing"

**Это НЕ ошибка!** LangSmith используется только для мониторинга и логирования. Studio и ваш чат работают нормально без LangSmith API key.

Если хотите использовать мониторинг:
1. Зарегистрируйтесь на [LangSmith](https://smith.langchain.com)
2. Получите API key: https://smith.langchain.com/settings
3. Добавьте в `.env`: `LANGSMITH_API_KEY=lsv2_pt_your-key-here`

### Ошибка: "Module not found" или "No module named 'state'"

Эта ошибка возникает, если пакет не установлен в режиме разработки. Выполните:

```bash
# Установите зависимости
pip install -r requirements.txt

# Установите пакет в режиме разработки (обязательно!)
pip install -e .
```

Убедитесь, что вы находитесь в корне проекта (где находится `pyproject.toml`).

### Ошибка: "Cannot find workflow"

Проверьте, что путь в `langgraph.json` правильный:

```json
"graphs": {
  "agent": "./langgraph_server/workflow.py:create_workflow"
}
```

### Ошибка: "OpenAI API key not found"

Убедитесь, что файл `.env` существует и содержит `OPENAI_API_KEY`.

### Studio не открывается в браузере

Попробуйте открыть вручную: `http://localhost:8123`

## Дополнительные ресурсы

- [LangGraph Documentation](https://langchain-ai.github.io/langgraph/)
- [LangGraph Studio Guide](https://langchain-ai.github.io/langgraph/tutorials/studio/)
- [LangGraph Cloud](https://cloud.langchain.com)

## Примечания

- LangGraph Studio работает с скомпилированным графом, поэтому все изменения в коде требуют перезапуска `langgraph dev`
- Для продакшена используйте отдельный FastAPI сервер (`main.py`), а не Studio
- Studio предназначен для разработки и отладки, не для продакшена

