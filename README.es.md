# agy-usage-winwidget

Una pequeña ventana flotante e icono en la bandeja del sistema (System Tray) para Windows que muestra tu cuota semanal de [Google Antigravity](https://antigravity.google): los mismos números que `/usage` en la CLI de Antigravity, actualizados automáticamente cada dos minutos.

```
┌──────────────────────────────────────┐
│ ⬡ USO DE ANTIGRAVITY     🔄  ▾ — ✕ │
│                                      │
│ MODELOS GEMINI           Flash, Pro  │
│ 7%                                   │
│ ██░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
│ se reinicia en 6d 23h                │
│                                      │
│ MODELOS CLAUDE Y GPT   Opus,Son,GPT  │
│ 100%                                 │
│ ███████████████████████████████████  │
│ límite alcanzado · se reinicia en 6d │
│                                      │
│ Antigravity                  21:35   │
└──────────────────────────────────────┘
```

[English](README.md) · **Español**

> **Basado en [Enhed/clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget)**
> creado por [Venger Sergey](https://github.com/Enhed) — un widget para Claude Code que inspiró la arquitectura, diseño de interfaz y patrones de este proyecto bajo licencia MIT. ¡Muchas gracias por crearlo y compartirlo con la comunidad! 🧡

---

## Características

- 📊 **Dos barras de progreso**: Modelos Gemini (Flash, Pro) y Modelos Claude y GPT (Opus, Sonnet, GPT-OSS), cada uno con su porcentaje de uso y cuenta regresiva de reinicio.
- 🎨 **Colores dinámicos**: verde → amarillo → rojo conforme aumenta el uso y supera los umbrales configurables.
- ⬡ **Icono hexagonal en la bandeja**: muestra el porcentaje más crítico de un vistazo.
- 📈 **Gráfico de historial**: despliega el panel de detalles para ver la evolución del uso en las últimas 24 horas.
- 🌐 **Soporte multilingüe**: español (`es`) e inglés (`en`), con detección automática de idioma (`auto`).
- 🔄 **Actualización automática**: consulta `agy -p "/usage"` en segundo plano cada 2 minutos (configurable).
- 💾 **Posición persistente**: recuerda en qué lugar de la pantalla colocaste la ventana.
- 🔍 **Zoom con la rueda del ratón**: rueda hacia arriba o abajo para escalar el tamaño de la ventana.
- 🖥️ **Sin dependencias externas**: funciona con Windows PowerShell 5.1 y WPF nativos de Windows 10/11. Solo necesitas tener instalada la CLI de Antigravity (`agy` en el `PATH`).

## Instalación

**Requisitos:** Windows 10 u 11 y la CLI de [Google Antigravity](https://antigravity.google) instalada e iniciada sesión (`agy` en el `PATH`).

- **Opción A (Recomendada):** Descarga el archivo de la [**última versión (Release ZIP)**](https://github.com/IberianSoldierPC/agy-usage-winwidget/releases/latest) y descomprímelo donde prefieras.
- **Opción B (Git):** Clona el repositorio:
  ```cmd
  git clone https://github.com/IberianSoldierPC/agy-usage-winwidget.git
  ```

Luego haz doble clic en **`start-widget.vbs`** — el widget se iniciará silenciosamente sin ventanas de consola.

### Inicio automático con Windows

Crea un acceso directo de `start-widget.vbs` y colócalo en tu carpeta de inicio:

```cmd
Win + R → shell:startup → pegar el acceso directo
```

## Uso

| Acción | Efecto |
|--------|--------|
| **Arrastrar la ventana** | Moverla a cualquier parte de la pantalla |
| **Rueda del ratón** | Escalar el widget (zoom) |
| **🔄 Actualizar** | Forzar recarga inmediata de cuota |
| **▾ / ▴ Desplegar** | Abrir o cerrar el panel de detalles |
| **— Minimizar** | Ocultar a la bandeja del sistema |
| **✕ Cerrar** | Salir del widget |
| **Clic izq. en bandeja** | Mostrar u ocultar la ventana |
| **Clic der. en bandeja** | Menú contextual (Mostrar, Actualizar, Salir) |

## Configuración

Edita el archivo `config.json` junto a `widget.ps1`:

| Clave | Por defecto | Descripción |
|-------|-------------|-------------|
| `refreshSeconds` | `10` | Intervalo de refresco de la interfaz (segundos) |
| `usageIntervalSeconds` | `120` | Frecuencia de consulta a `agy /usage` (segundos) |
| `expanded` | `false` | Iniciar con el panel de detalles abierto |
| `scale` | `1.35` | Factor de escala de la ventana |
| `warnPercent` | `60` | Umbral de advertencia amarillo (% usado) |
| `critPercent` | `85` | Umbral crítico rojo (% usado) |
| `showRemaining` | `false` | Si es `true`, muestra % restante en vez de % usado |
| `language` | `"es"` | Idioma de la interfaz (`"es"`, `"en"` o `"auto"`) |
| `opacity` | `1.0` | Opacidad de la ventana (0.0 a 1.0) |
| `topmost` | `false` | Mantener la ventana siempre al frente |

## Origen de los datos

El widget ejecuta de forma desatendida:

```cmd
agy -p "/usage" --output-format json
```

Son los mismos datos oficiales que devuelve el comando `/usage` dentro de Antigravity. **No realiza llamadas a modelos ni gasta tokens**.

## Créditos

Este proyecto es una adaptación de **[clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget)** por [Venger Sergey](https://github.com/Enhed), publicado bajo [Licencia MIT](https://github.com/Enhed/clawd-usage-winwidget/blob/main/LICENSE).

## Licencia

[MIT](LICENSE) — la misma que el proyecto original.
