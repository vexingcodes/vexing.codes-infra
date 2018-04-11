var aws = require("aws-sdk");
aws.config.update({ region: "${region}" });
exports.handler = (event, context, callback) => {
  var sns = new aws.SNS();
  sns.publish({
    Message: event.Records[0].cf.request.querystring,
    TopicArn: "${topic_arn}"
  }, function(err, data) {
    if (err) {
      console.log("error: " + err);
      callback(null, { body: err, status: "500" });
    } else {
      console.log("success");
      callback(null, { status: "204" });
    }
  });
};
