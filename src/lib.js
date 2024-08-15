mergeInto(LibraryManager.library, {
  js_save_high_score: function (score, name_ptr, name_len) {
    const name = UTF8ToString(name_ptr, name_len);
    // save name locally
    localStorage.setItem("name", name);

    // load existing high scores
    const highScores = localStorage.getItem("highScores") || [];
    highScores.push({ score: score, name: name });
    highScores.sort((a, b) => b.score - a.score);
    highScores.slice(0, 3);

    localStorage.setItem("highScores", JSON.stringify(highScores));

    // send score to server
    fetch("/api/save_high_score", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ score: score, name: name }),
    })
      .then((response) => response.json())
      .then((data) => console.log("High score saved: ", data))
      .catch((error) => console.error(error));
  },

  js_load_high_scores: function (high_scores_ptr) {
    // fetch high score from server
    var highScores = Module.lastKnownHighScores || [];
    fetch("/api/load_high_scores")
      .then((response) => response.json())
      .then((highScores) => {
        console.log("High scores loaded: ", highScores);
        Module.lastKnownHighScore = data;
        const highScoresBuffer = new Uint8Array(
          Module.HEAPU8.buffer,
          high_scores_ptr,
          3 * (6 + 4),
        );

        for (let i = 0; i < 3; i++) {
          const score = highScores[i] || { name: "", score: 0 };
          const nameBuffer = new Uint8Array(
            highScoresBuffer.buffer,
            high_scores_ptr + i * (6 + 4),
            6,
          );
          const scoreView = new DataView(
            highScoresBuffer.buffer,
            high_scores_ptr + i * (6 + 4) + 6,
            4,
          );

          const encoder = new TextEncoder();
          const encodedName = encoder.encode(
            score.name.padEnd(5, " ").slice(0, 5),
          );
          nameBuffer.set(encodedName);
          nameBuffer[5] = 0;

          scoreView.setUint32(0, score.score, true);
        }
      })
      .catch((error) => console.error(error));
  },

  js_load_player_name: function (name_ptr) {
    const storedName = localStorage.getItem("name") || "";
    const nameBuffer = Module.HEAPU8.subarray(name_ptr, name_ptr + 5);
    const encoder = new TextEncoder();
    const encodedName = encoder.encode(storedName.slice(0, 5));
    nameBuffer.set(encodedName);
    return Math.min(storedName.length, 5);
  },
});
