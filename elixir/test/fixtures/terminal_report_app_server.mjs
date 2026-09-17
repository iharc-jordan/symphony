import readline from "node:readline";

const threadId = "thread-terminal-report";
const turnId = "turn-terminal-report";
const input = readline.createInterface({ input: process.stdin });

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

input.on("line", (line) => {
  const message = JSON.parse(line);

  if (message.method === "turn/start") {
    send({ id: message.id, result: { turn: { id: turnId } } });
    send({
      id: 91,
      method: "item/tool/call",
      params: {
        tool: "orchestration_report",
        arguments: {
          kind: "result",
          report_id: "report-terminal",
          summary: "completed",
          evidence: [],
        },
      },
    });
    return;
  }

  if (message.method === "turn/interrupt") {
    send({
      method: "turn/completed",
      params: {
        threadId,
        turn: {
          id: turnId,
          status: "interrupted",
          usage: { input_tokens: 10, output_tokens: 2 },
        },
      },
    });
  }
});
