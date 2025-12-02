# Реализация LangGraph Step-by-Step Agent для Ableton Assistant

## Архитектура

**Гибридный подход:**

- **Python сервер**: FastAPI + LangGraph workflow (HTTP API на порту 8000)
- **Swift клиент**: HTTP запросы к Python серверу, обработка UI и скриншотов
- **Состояние**: В памяти Python сервера по `session_id` (не сохраняется между перезапусками)
- **Скриншоты**: Multipart form-data для передачи из Swift в Python

## 1. Python сервер (FastAPI + LangGraph)

### 1.1 Структура проекта

Создать `langgraph_server/` в корне проекта:

- `langgraph_server/main.py` - FastAPI приложение
- `langgraph_server/workflow.py` - LangGraph workflow определение
- `langgraph_server/nodes.py` - Все ноды workflow
- `langgraph_server/state.py` - Определение State класса


### 1.3 Основные ноды (`langgraph_server/nodes.py`)

**1. detect_user_intent** - Определение намерения пользователя

- Вход: `user_query`
- Выход: `intent = "ableton_question" | "other"`
- Использует LLM для классификации

**2. check_ableton_version** - Проверка совместимости версии

- Вход: `user_query`, `ableton_version`
- Загружает `data/Ableton-versions-diff-chunks-with-embeddings.json`
- Поиск по эмбеддингам запроса
- Выход: `allowed = true/false`, `version_explanation` (если false)
- Если `allowed == false`: переход к `wait_for_version_choice`
- Если `allowed == true`: переход к `retrieve_from_vectorstore`

**2a. wait_for_version_choice** - Ожидание выбора пользователя при несовместимости версии

- Вход: `version_explanation` (предупреждение о несовместимости)
- Показывает пользователю предупреждение: "В текущей версии это скорее всего не получится из-за ограничений: {version_explanation}"
- Предлагает выбор: "Все равно попробовать" или "Сформулировать новую задачу"
- Вход: ответ пользователя
- Если "Сформулировать новую задачу" → завершить workflow
- Если "Все равно попробовать" → переход к `retrieve_from_vectorstore`

**3. retrieve_from_vectorstore** - Поиск в документации

- Вход: `user_query`
- Загружает `data/live12-manual-chunks-with-embeddings.json`
- Поиск 3-10 релевантных chunks
- Выход: `selected_chunks`

**4. generate_full_answer** - Генерация полного ответа

- Вход: `user_query`, `selected_chunks`, `allowed`, `version_explanation`
- Генерирует полное объяснение + пошаговую инструкцию
- Парсит steps из ответа LLM (JSON формат)
- Сохраняет `steps[]` в state
- Выход: `full_answer`, `steps[]`

**5. wait_for_user_step_choice** - Ожидание выбора пользователя

- Вход: ответ пользователя (да/нет)
- Выход: переход к `step_agent_start` или завершение

**6. step_agent_start** - Инициализация пошагового режима

- Инициализирует: `current_step_index = 0`, `steps_total = len(steps)`, `mode = "step_by_step"`
- Отправляет первый шаг пользователю

**7. detect_interaction_type** - Определение типа взаимодействия

- Анализирует текущий шаг (`steps[current_step_index]`)
- Определяет: требуется ли клик или только действие пользователя
- Устанавливает `step.requires_click = true/false`

**8. analyze_screenshot_for_button** - Анализ скриншота для координат

- Вход: скриншот (multipart), `step_text`
- Использует Vision API (GPT-4 Vision) для анализа
- Промпт: "Анализируй скриншот и верни координаты кнопки, соответствующей инструкции: {step_text}. Верни JSON: {x, y, width, height}"
- Выход: `step.button_coords`

**9. wait_user_action** - Ожидание действия пользователя

- Вход: текст пользователя или кнопки ("Дальше", "Пропустить шаг", "Отменить задачу")
- Выход: действие для следующего шага

**10. optional_validate_step** - Опциональная валидация шага

- Если `step.requires_click == true`:
  - Делает новый скриншот (Swift отправляет)
  - Анализирует через Vision API: "Видишь ли ты состояние после выполнения шага: {step_text}? Верни yes/no + объяснение"
- Если `no` → возвращает ошибку пользователю
- Если пользователь сказал "Пропустить" → пропускает валидацию

**11. next_step_or_finish** - Переход к следующему шагу

- Если `current_step_index < steps_total - 1`:
  - `current_step_index++`
  - Переход к `detect_interaction_type`
- Иначе → переход к `final_confirmation`

**12. final_confirmation** - Финальное подтверждение

- Спрашивает: "Удалось ли решить исходную задачу?"
- Если да → завершение workflow
- Если нет → переход к `fallback_review_steps`

**13. fallback_review_steps** - Fallback ветка

- Проходит по всем `steps[]`
- Для каждого шага спрашивает: "Выполнен ли шаг X?"
- Если нет → предлагает помощь с этим шагом
- Возврат к `step_agent_start` с этим шагом как первым

### 1.4 LangGraph Workflow (`langgraph_server/workflow.py`)

Определить граф с условными переходами:

- `detect_user_intent` → если `other`, завершить; иначе → `check_ableton_version`
- `check_ableton_version` → если `allowed == false` → `wait_for_version_choice`; если `allowed == true` → `retrieve_from_vectorstore`
- `wait_for_version_choice` → если "Сформулировать новую задачу" → завершить; если "Все равно попробовать" → `retrieve_from_vectorstore`
- `retrieve_from_vectorstore` → `generate_full_answer`
- `generate_full_answer` → `wait_for_user_step_choice`
- `wait_for_user_step_choice` → если "да" → `step_agent_start`; иначе завершить
- `step_agent_start` → `detect_interaction_type`
- `detect_interaction_type` → если `requires_click` → `analyze_screenshot_for_button`; иначе → `wait_user_action`
- `analyze_screenshot_for_button` → `wait_user_action`
- `wait_user_action` → если "Отменить" → завершить; если "Пропустить" → `next_step_or_finish`; иначе → `optional_validate_st
