import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property color muted: Color.muted
  property color urgent: Color.urgent
  property string surfaceKey: ""
  property bool cancelHasCursor: false
  property bool confirmHasCursor: false
  readonly property string availability: service
    ? String(service.lyricsPluginAvailability || "missing") : "missing"
  readonly property bool busy: service && service.lyricsPluginBusy
  readonly property string errorText: service
    ? String(service.lyricsPluginError || "") : ""

  signal canceled()

  implicitWidth: Style.space(340)
  implicitHeight: promptContent.implicitHeight
  height: implicitHeight

  Column {
    id: promptContent
    width: parent.width
    spacing: Style.space(9)

    Text {
      objectName: "lyrics-install-title"
      width: parent.width
      text: root.availability === "disabled" ? "¿Activar letras de Omasing?"
        : (root.availability === "ready" && root.errorText
          ? "Omasing no se abrió" : "¿Instalar letras de Omasing?")
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      objectName: "lyrics-install-description"
      width: parent.width
      text: root.availability === "disabled"
        ? "Omasing ya está instalado. ¿Quieres activarlo y añadir su widget al centro de la barra?"
        : (root.availability === "ready"
          ? "El plugin está instalado, pero Spotify no pudo abrir su ventana de letras."
          : "Las letras las ofrece el plugin opcional Omasing. ¿Quieres instalarlo y activarlo ahora?")
      color: root.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: root.availability === "missing"
      text: "Esto descarga github.com/stappmus/Omasing. Los plugins de Omarchy se ejecutan sin aislamiento dentro de la shell."
      color: root.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      objectName: "lyrics-install-error"
      width: parent.width
      visible: text !== ""
      text: root.errorText
      color: root.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Button {
        objectName: "lyrics-install-cancel"
        width: (parent.width - parent.spacing) / 2
        text: "Cancelar"
        foreground: root.foreground
        focusable: true
        hasCursor: root.cancelHasCursor
        enabled: !root.busy
        onClicked: root.canceled()
      }

      Button {
        objectName: "lyrics-install-confirm"
        width: (parent.width - parent.spacing) / 2
        text: root.busy
          ? (root.service && root.service.lyricsPluginOperation === "disabled"
            ? "Activando…" : "Instalando…")
          : (root.availability === "disabled" ? "Activar"
            : (root.availability === "ready" ? "Reintentar" : "Instalar"))
        iconText: root.availability === "ready" ? "󰑓" : "󰐕"
        foreground: root.foreground
        selected: true
        focusable: true
        hasCursor: root.confirmHasCursor
        enabled: root.service && !root.busy
        onClicked: root.service.confirmLyricsPlugin(root.surfaceKey)
      }
    }
  }
}
